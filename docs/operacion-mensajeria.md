# Operación de mensajería

La fase 8 se ejecuta desde la instancia DevOps del producto. La API, los Workers y el AppHost siguen
publicando y consumiendo recursos existentes; no administran alertas ni recuperaciones. La decisión
está en [ADR 0009](adr/0009-operacion-de-mensajeria-por-consumidor.md).

## Política por consumidor

Guarda `messaging-operations-policy.json` junto al descriptor y la política física del ambiente:

```text
products/<producto>/environments/<ambiente>/
  descriptor.json
  azure-service-bus-policy.json   # o aws-sns-sqs-policy.json / rabbitmq-policy.json
  messaging-operations-policy.json
```

El [ejemplo AWS](../examples/messaging-operations-policy.json) satisface el
[JSON Schema v1](../contracts/schemas/messaging-operations-policy-v1.schema.json). Declara todos y
solo los consumidores de la política física. Cada consumidor decide:

| Campo | Efecto |
| --- | --- |
| `backlogThreshold` | Alarma por mensajes pendientes |
| `deadLetterThreshold` | Umbral DLQ; `null` cuando esa cola no tiene DLQ |
| `oldestMessageAgeSeconds` | Umbral de antigüedad en SQS; `null` para Azure/RabbitMQ |
| `quarantineReviewHours` | Plazo humano de revisión; `0` sin DLQ; nunca borra mensajes |
| `replay.enabled` | Habilita recuperar esa DLQ; debe ser `false` si no existe |
| `replay.maxBatchSize` | Máximo de mensajes por ejecución, entre 1 y 100 |
| `replay.delayMilliseconds` | Pausa entre mensajes, entre 100 y 10000 ms |

`operatorIdentities` asigna a cada consumidor una identidad existente: UUID de principal Azure,
nombre de rol IAM o usuario RabbitMQ. Debe ser distinta para cada consumidor y distinta de todas
las identidades de los workloads. No declara contraseñas ni crea usuarios. Para Azure usa Action
Groups existentes en `notificationTargets`; para AWS, topics SNS de alertas existentes; RabbitMQ
usa una lista vacía porque Alertmanager administra sus notificaciones.

```powershell
pwsh ./scripts/Test-MessagingOperationsPolicy.ps1 `
  -Policy products/hexagon-example/environments/dev/messaging-operations-policy.json `
  -TopologyPolicy products/hexagon-example/environments/dev/aws-sns-sqs-policy.json
```

Para Azure, todos sus consumidores tienen DLQ y por tanto umbral y plazo de revisión. Para AWS y
RabbitMQ se respeta la elección individual de la política física. Sin DLQ no hay recuperación
desde el broker después del descarte; cualquier compensación debe diseñarse en el producto.

## Materializar alertas y permisos

```powershell
pwsh ./scripts/Export-MessagingOperations.ps1 `
  -Descriptor products/hexagon-example/environments/dev/descriptor.json `
  -TopologyPolicy products/hexagon-example/environments/dev/aws-sns-sqs-policy.json `
  -Policy products/hexagon-example/environments/dev/messaging-operations-policy.json `
  -OutputDirectory operations/generated/hexagon-example/dev
```

El script verifica commit y SHA-256 de los contratos remotos, reutiliza la correspondencia completa
del proveedor y valida operaciones antes de escribir. `-WhatIf` no consulta GitHub ni genera archivos.
Produce `operations.auto.tfvars.json`, que se entrega al mismo root y estado de Terraform donde se
aplica la topología física, junto a sus variables de topología. Nunca se usa como un estado paralelo.
Su omisión conserva la composición anterior; habilitar operación requiere aportar la política.

Azure crea alertas por topic `ActiveMessages` y `DeadletteredMessages`, con evaluación cada minuto y
ventana de cinco minutos, umbral mínimo entre consumidores y Action Groups declarados. No presenta
esas métricas como si fueran de suscripción. Para localizar el consumidor se usa la inspección de
cada DLQ. No inventa una métrica nativa de antigüedad por suscripción.

AWS crea alarmas por cola `ApproximateNumberOfMessagesVisible` y `ApproximateAgeOfOldestMessage`, y
por DLQ `ApproximateNumberOfMessagesVisible` cuando existe. Exige dos períodos de un minuto y usa
`Maximum`; los períodos sin datos no se interpretan como backlog. El monitoreo del pipeline de
telemetría y de salud de los Workers debe acompañar estas señales: ausencia de datos no demuestra
salud.

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
| Azure Service Bus | La DLQ ignora TTL; conserva hasta retirada deliberada | Revisar antes del plazo y vigilar capacidad |
| SQS estándar | Usa la retención DLQ y conserva el timestamp de envío original | Revisar antes de `retención DLQ − retención origen` |
| RabbitMQ | DLQ sin TTL ni expiración y con `delivery-limit = -1` | Revisar plazo y capacidad; no reintentar en bucle |

La política física sigue controlando TTL/retención. El validador rechaza un plazo de revisión SQS
que alcance la peor ventana restante o un umbral de antigüedad que alcance la retención fuente.
Las DLQ no reciben consumidores de negocio. No hay purga automática, edición de cuerpos ni exportación
de mensajes a archivos de diagnóstico. Si un incidente requiere conservar datos más tiempo que SQS
permite, su dueño debe diseñar almacenamiento cifrado y restringido antes del vencimiento.

Mantén los registros del inbox durante toda la ventana máxima de reentrega y recuperación. El core
actual no los elimina automáticamente. Renombrar un handler cambia su identidad; añadir handlers o
reproducir contra otra versión exige revisar los efectos que todavía no tienen confirmación.

## Inspección y recuperación

Primero exporta los outputs no secretos del root aplicado con `terraform output -json` a un archivo
local ignorado por Git. Vuelve a ejecutar el materializador anterior añadiendo
`-TerraformOutputs <archivo.json>`. Verifica nombres físicos y genera `<consumidor>.target.json`.
Estos destinos corresponden al producto, ambiente y contrato aplicado; regénéralos después de cada
cambio y revisa su diff. Los actuales endpoints operativos son Azure público y SQS `amazonaws.com`.

La herramienta requiere PowerShell 7, .NET 10 y las credenciales del operador en el ambiente:

- Azure: identidad con Data Receiver en la suscripción y Data Sender en el topic. Usa
  `DefaultAzureCredential`; no acepta connection strings cloud. Azure no permite limitar Data
  Receiver únicamente a la subcola DLQ.
- AWS: cadena de credenciales del SDK, región del destino, `GetQueueAttributes` en origen/DLQ,
  `ReceiveMessage`, `ChangeMessageVisibility`, `DeleteMessage` solo en DLQ y `SendMessage` solo en
  origen. Terraform no concede permisos de recuperación cuando no hay DLQ.
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

Azure muestra una muestra acotada de metadatos canónicos, sin el cuerpo ni descripciones de error
libres. AWS muestra conteos y retención; RabbitMQ muestra conteos y consumidores. Una estadística
RabbitMQ todavía no publicada aparece como `null`, nunca como cero inventado. Inspeccionar no recibe,
confirma ni cambia la visibilidad de mensajes. SQS y RabbitMQ no ofrecen aquí un peek de cuerpos.

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

En Azure el ID de transporte es un hash estable de incidente + `HexagonMessageId`; así evita la
deduplicación del envío original y permite repetir un envío incierto del mismo incidente. Azure
publica al topic y RabbitMQ al exchange original, por lo que puede haber fanout. SQS publica solo en
la cola fuente. En todos los casos `HexagonMessageId`, el tenant y el tipo se conservan y el inbox
omite cada handler ya confirmado. La publicación y el retiro de la DLQ son operaciones distintas:
una caída entre ambas puede duplicar la entrega. Usa el mismo incidente al reconciliar ese caso.

El stdout es JSON por evento: inicio, intento, publicación confirmada, retiro confirmado y resultado.
Solo registra IDs técnicos, conteos y tipo de excepción; no tenant, cuerpo, secretos, receipt handles
ni excepciones libres. Enlázalo con la identidad autenticada del operador en los logs de acceso del
proveedor. Conserva ese rastro según la política de auditoría del producto. No guardes logs completos
del SDK ni agregues identificadores personales al UUID del incidente.

Para emuladores únicamente en `dev`, `-Local` permite conexión Azure loopback desde
`HEXAGON_OPERATIONS_CONNECTION_STRING`, AWS loopback desde `HEXAGON_OPERATIONS_AWS_ENDPOINT` y
RabbitMQ AMQP/HTTP loopback. Ninguna de estas excepciones permite plaintext contra hosts remotos.

## Pruebas

`Test-Repository.ps1` valida políticas, casos inválidos, generación local, las raíces Terraform y
las pruebas unitarias de la herramienta. La prueba integral se ejecuta aparte con Docker:

```powershell
$env:HEXAGON_RUN_BROKER_TESTS = '1'
dotnet test operations/Hexagon.Messaging.Operations.Tests --filter 'Category=Broker'
```

La prueba Azure acepta las licencias del emulador y SQL Server al crear contenedores efímeros.
Las fixtures crean y retiran únicamente recursos de prueba. Cubren recuperación, sobre inalterado,
límites, fallos y conservación de cuarentena. No despliegan infraestructura compartida ni pipelines.

## Referencias

- [Azure: DLQ y ausencia de TTL](https://learn.microsoft.com/en-us/azure/service-bus-messaging/service-bus-dead-letter-queues).
- [Azure: detección de duplicados por MessageId](https://learn.microsoft.com/en-us/azure/service-bus-messaging/duplicate-detection).
- [Azure: métricas y dimensión EntityName](https://learn.microsoft.com/en-us/azure/service-bus-messaging/monitor-service-bus-reference).
- [AWS: retención de DLQ estándar](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-dead-letter-queues.html).
- [RabbitMQ: métricas por objeto](https://www.rabbitmq.com/docs/prometheus).
- [RabbitMQ 4.1: límites de entrega quorum](https://www.rabbitmq.com/docs/4.1/quorum-queues).
- [RabbitMQ: confirmaciones de publicación](https://www.rabbitmq.com/docs/confirms).
