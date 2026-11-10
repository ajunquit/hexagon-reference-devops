# ADR 0009: operación de mensajería por consumidor

- Estado: aceptada
- Fecha: 2026-11-09

## Contexto

Las fases 1–7 separan requisitos lógicos, topología física y ejecución. Falta definir quién puede
inspeccionar y recuperar mensajes fallidos, qué se observa y qué ocurre con una cola sin DLQ.
El procedimiento debe conservar la identidad del inbox y las diferencias reales entre brokers.

## Decisión

DevOps mantiene `MessagingOperationsPolicy` v1 por producto, ambiente y consumidor, junto a la
política física. Declara umbrales, identidades operativas distintas de las aplicaciones, plazo de
revisión de cuarentena y recuperación habilitada o deshabilitada con límite y pausa por mensaje.
No modifica el manifiesto backend ni permite activar DLQ desde la aplicación.

- Azure usa alertas Azure Monitor por topic, porque `EntityName` no distingue suscripciones.
  Los umbrales de sus consumidores se agrupan usando el menor. La inspección usa peek de la DLQ.
- AWS usa CloudWatch por cola para backlog, antigüedad y la DLQ que exista. La inspección solo usa
  atributos agregados: SQS no tiene peek pasivo.
- RabbitMQ entrega reglas Prometheus por vhost/cola y permisos para usuarios existentes; su hosting
  instala el plugin y configura el scrape por objeto y Alertmanager. La inspección usa HTTP GET de
  metadatos, nunca `basic.get` ni el endpoint de lectura de mensajes.
- La DLQ existente es la cuarentena. Una cola sin DLQ no tiene cuarentena, alerta DLQ ni recuperación
  automática. No se crea una segunda copia de cuerpos sensibles para diagnóstico.
- Las DLQ RabbitMQ usan una política `delivery-limit = -1`: repetir un intento operativo fallido no
  puede agotar el límite quorum predeterminado y descartar el mensaje. No se cambia su declaración.

La herramienta de operaciones vive en DevOps, usa los SDK de transporte y no depende de
`Hexagon.Core`, de módulos de negocio ni del backend. Consume destinos generados desde contratos
verificados y outputs de Terraform; no acepta una dirección de reenvío como argumento libre.

La reproducción exige producto, ambiente y consumidor explícitos, un incidente UUID, política
habilitada y un lote acotado. El wrapper hace un plan por defecto; solo `-Execute` conecta para
reproducir. Conserva cuerpo y propiedades canónicas, incluido `HexagonMessageId` y el tenant. Solo
retira el original después de publicar con confirmación. No promete atomicidad entre publicación
y confirmación de la DLQ: una caída puede duplicar una entrega y el inbox debe absorberla.

En Azure, el nuevo `MessageId` del transporte se deriva del incidente y de `HexagonMessageId`, para
evitar que la detección de duplicados suprima la recuperación. La identidad del inbox se conserva.
Azure reenvía al topic y RabbitMQ al exchange: pueden recibirlo otros consumidores, cuyos handlers
ya confirmados se omiten mientras conserven la misma identidad y sus registros de inbox. AWS envía
directamente a la cola fuente, conservando sus atributos.

## Consecuencias

- La operación no amplía permisos de las aplicaciones ni introduce endpoints administrativos.
- Roles y usuarios operativos, Action Groups y topics de notificaciones deben existir; Terraform
  asigna permisos y define alertas. Prometheus/Alertmanager y su instalación pertenecen al hosting.
- Azure limita Data Receiver a la suscripción, pero ese permiso alcanza su cola activa y su DLQ;
  el wrapper solo recupera desde DLQ. RabbitMQ requiere el tag `management` para HTTP y permisos de
  lectura de sus colas. Estos límites de autorización no se ocultan.
- Azure DLQ y RabbitMQ conservan cuarentena sin TTL automático; AWS elimina al expirar su retención.
  El plazo de revisión es un SLO operativo, no una orden de purga. En SQS debe ser menor que la
  retención DLQ menos la retención de origen, por el timestamp original de las colas estándar.
- Los logs contienen identificadores técnicos, resultados y conteos; no cuerpos, tenant, claves,
  receipt handles, headers arbitrarios ni mensajes de excepción de los SDK.
- No se añaden pipelines ni se aplican recursos contra ambientes compartidos en esta fase.
