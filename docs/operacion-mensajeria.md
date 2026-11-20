# Operación de mensajería

La fase 8 se ejecuta desde la instancia DevOps del producto. La API, los Workers y el AppHost siguen
publicando y consumiendo recursos existentes; no administran alertas ni recuperaciones. La decisión
está en [ADR 0009](adr/0009-operacion-de-mensajeria-por-consumidor.md).

Esta guía es común a todos los proveedores. Cada proveedor declara sus reglas en
`scripts/<Proveedor>OperationsPolicy.psm1`, y la guía de operación de cada nube completa los detalles
de sus alertas, identidades y recuperación.

## Política por consumidor

Guarda `messaging-operations-policy.json` junto al descriptor y la política física del ambiente:

```text
products/<producto>/environments/<ambiente>/
  descriptor.json
  <proveedor>-policy.json         # p. ej. rabbitmq-policy.json
  messaging-operations-policy.json
```

El [ejemplo con RabbitMQ](../examples/messaging-operations-policy.json) satisface el
[JSON Schema v1](../contracts/schemas/messaging-operations-policy-v1.schema.json). Declara todos y
solo los consumidores de la política física. Cada consumidor decide:

| Campo | Efecto |
| --- | --- |
| `backlogThreshold` | Alarma por mensajes pendientes |
| `deadLetterThreshold` | Umbral DLQ; `null` cuando esa cola no tiene DLQ |
| `oldestMessageAgeSeconds` | Umbral de antigüedad, solo si el proveedor tiene esa métrica por cola; `null` en RabbitMQ |
| `quarantineReviewHours` | Plazo humano de revisión; `0` sin DLQ; nunca borra mensajes |
| `replay.enabled` | Habilita recuperar esa DLQ; debe ser `false` si no existe |
| `replay.maxBatchSize` | Máximo de mensajes por ejecución, entre 1 y 100 |
| `replay.delayMilliseconds` | Pausa entre mensajes, entre 100 y 10000 ms |

`operatorIdentities` asigna a cada consumidor una identidad existente del proveedor; en RabbitMQ, un
usuario. Debe ser distinta para cada consumidor y distinta de todas las identidades de los workloads.
No declara contraseñas ni crea usuarios. `notificationTargets` lista los destinos de alertas que el
proveedor admite; RabbitMQ usa una lista vacía porque Alertmanager administra sus notificaciones.

```powershell
pwsh ./scripts/Test-MessagingOperationsPolicy.ps1 `
  -Policy products/hexagon-example/environments/dev/messaging-operations-policy.json `
  -TopologyPolicy products/hexagon-example/environments/dev/rabbitmq-policy.json
```

Un consumidor con DLQ requiere umbral y plazo de revisión. Cada proveedor decide qué colas tienen
DLQ; en RabbitMQ se respeta la elección individual de la política física. Sin DLQ no hay recuperación
desde el broker después del descarte; cualquier compensación debe diseñarse en el producto.

## Materializar alertas y permisos

```powershell
pwsh ./scripts/Export-MessagingOperations.ps1 `
  -Descriptor products/hexagon-example/environments/dev/descriptor.json `
  -TopologyPolicy products/hexagon-example/environments/dev/rabbitmq-policy.json `
  -Policy products/hexagon-example/environments/dev/messaging-operations-policy.json `
  -OutputDirectory operations/generated/hexagon-example/dev
```

El script verifica commit y SHA-256 de los contratos remotos, reutiliza la correspondencia completa
del proveedor y valida operaciones antes de escribir. `-WhatIf` no consulta GitHub ni genera archivos.
Produce `operations.auto.tfvars.json`, que se entrega al mismo root y estado de Terraform donde se
aplica la topología física, junto a sus variables de topología. Nunca se usa como un estado paralelo.
Su omisión conserva la composición anterior; habilitar operación requiere aportar la política.

Cada nube crea las alertas nativas de su broker; su guía de operación las describe.

RabbitMQ produce además `messaging.rules.json`, un documento YAML compatible por ser JSON. Cárgalo
en `rule_files` de Prometheus y enruta sus labels `product`, `environment`, `consumer` y `severity`
desde Alertmanager. Incluye backlog, DLQ opcional, falta de consumidores con backlog y falta de
métricas por cola. El hosting debe habilitar `rabbitmq_prometheus` y scrape de `/metrics/per-object`;
el endpoint agregado por defecto no conserva las etiquetas de cada cola. Debe estar protegido por
red/TLS y recolectarse sin duplicar series. La fase 8 entrega reglas; su instalación y despliegue
pertenecen a la futura composición de hosting.

Los paneles pueden usar esas mismas señales y dimensiones técnicas. No deben etiquetar por tenant,
correo, cuerpo, `HexagonMessageId` ni texto de error: además de privacidad, aumentaría la cardinalidad.

## Retención y cuarentena

| Broker | Retención de cuarentena | Actuación |
| --- | --- | --- |
| RabbitMQ | DLQ sin TTL ni expiración y con `delivery-limit = -1` | Revisar plazo y capacidad; no reintentar en bucle |

La retención de cada nube está en su guía de operación. La política física sigue controlando
TTL/retención. Las DLQ no reciben consumidores de negocio. No hay purga automática, edición de cuerpos
ni exportación de mensajes a archivos de diagnóstico. Si un incidente requiere conservar datos más
tiempo que el broker permite, su dueño debe diseñar almacenamiento cifrado y restringido antes del
vencimiento.

Mantén los registros del inbox durante toda la ventana máxima de reentrega y recuperación. El core
actual no los elimina automáticamente. Renombrar un handler cambia su identidad; añadir handlers o
reproducir contra otra versión exige revisar los efectos que todavía no tienen confirmación.

## Inspección y recuperación

Primero exporta los outputs no secretos del root aplicado con `terraform output -json` a un archivo
local ignorado por Git. Vuelve a ejecutar el materializador anterior añadiendo
`-TerraformOutputs <archivo.json>`. Verifica nombres físicos y genera `<consumidor>.target.json`.
Estos destinos corresponden al producto, ambiente y contrato aplicado; regénéralos después de cada
cambio y revisa su diff. Cada proveedor valida sus endpoints operativos.

La herramienta requiere PowerShell 7, .NET 10 y las credenciales del operador en el ambiente. Los
permisos de cada nube están en su guía de operación:

- RabbitMQ: `HEXAGON_OPERATIONS_CONNECTION_STRING` con AMQPS, vhost e identidad de operaciones.
  Para inspección añade `HEXAGON_OPERATIONS_RABBITMQ_MANAGEMENT_URL` HTTPS del mismo host y tag
  `management` en ese usuario existente. Terraform concede lectura solo de sus colas, publicación
  solo al exchange/tipos permitidos y ningún `configure`. Los secretos vienen del gestor, nunca de
  archivos ni argumentos del comando.

```powershell
pwsh ./scripts/Invoke-MessagingOperation.ps1 `
  -Action Inspect `
  -Target operations/generated/hexagon-example/dev/sales-worker.target.json `
  -Product hexagon-example -Environment dev -Consumer sales-worker
```

RabbitMQ muestra conteos y consumidores; cada nube describe su inspección en su guía. Una estadística
RabbitMQ todavía no publicada aparece como `null`, nunca como cero inventado. Inspeccionar no recibe,
confirma ni cambia la visibilidad de mensajes. RabbitMQ no ofrece aquí un peek de cuerpos.

Procedimiento de incidente:

1. Identifica consumidor y causa mediante métricas, salud y logs saneados; asigna un incidente UUID.
2. Corrige la causa y comprueba el despliegue y las dependencias. Revisa el posible fanout y la
   identidad de los handlers; no borres filas del inbox para forzar una repetición.
3. Revisa un plan de lote pequeño. `Replay` sin `-Execute` produce solo el plan, sin conexión al broker.
4. Ejecuta deliberadamente ese lote con `-Execute`; valida resultados antes de otro lote.
5. Archiva el registro técnico del incidente con acceso restringido, monitorea DLQ/backlog y cierra
   cuando los handlers pendientes hayan confirmado. El ack del broker por sí solo no prueba éxito
   de negocio.

```powershell
pwsh ./scripts/Invoke-MessagingOperation.ps1 `
  -Action Replay `
  -Target operations/generated/hexagon-example/dev/sales-worker.target.json `
  -Product hexagon-example -Environment dev -Consumer sales-worker `
  -Incident 00000000-0000-0000-0000-000000000001 -Limit 1
# Después de revisar el plan, repite con -Execute.
```

`-WhatIf` no compila ni conecta. El proceso tiene timeout de tres minutos; un lote puede terminar
parcialmente y deja constancia por mensaje. Conserva cuerpo y propiedades canónicas sin modificarlos;
rechaza identidades, tipos o pares de tenant inválidos antes de publicar y conserva el original.
No lee ni escribe el inbox directamente.

RabbitMQ publica al exchange original, por lo que puede haber fanout; cada nube indica a dónde
publica. En todos los casos `HexagonMessageId`, el tenant y el tipo se conservan y el inbox
omite cada handler ya confirmado. La publicación y el retiro de la DLQ son operaciones distintas:
una caída entre ambas puede duplicar la entrega. Usa el mismo incidente al reconciliar ese caso.

El stdout es JSON por evento: inicio, intento, publicación confirmada, retiro confirmado y resultado.
Solo registra IDs técnicos, conteos y tipo de excepción; no tenant, cuerpo, secretos, receipt handles
ni excepciones libres. Enlázalo con la identidad autenticada del operador en los logs de acceso del
proveedor. Conserva ese rastro según la política de auditoría del producto. No guardes logs completos
del SDK ni agregues identificadores personales al UUID del incidente.

Para emuladores únicamente en `dev`, `-Local` permite conexiones loopback: RabbitMQ AMQP/HTTP y las
que cada nube indica. Ninguna de estas excepciones permite plaintext contra hosts remotos.

## Pruebas

`Test-Repository.ps1` valida políticas, casos inválidos, generación local, las raíces Terraform y
las pruebas unitarias de la herramienta. La prueba integral se ejecuta aparte con Docker:

```powershell
$env:HEXAGON_RUN_BROKER_TESTS = '1'
dotnet test operations/Hexagon.Messaging.Operations.Tests --filter 'Category=Broker'
```

Si un emulador exige aceptar licencias, su prueba las acepta solo para los contenedores efímeros.
Las fixtures crean y retiran únicamente recursos de prueba. Cubren recuperación, sobre inalterado,
límites, fallos y conservación de cuarentena. No despliegan infraestructura compartida ni pipelines.

## Referencias

- [RabbitMQ: métricas por objeto](https://www.rabbitmq.com/docs/prometheus).
- [RabbitMQ 4.1: límites de entrega quorum](https://www.rabbitmq.com/docs/4.1/quorum-queues).
- [RabbitMQ: confirmaciones de publicación](https://www.rabbitmq.com/docs/confirms).
