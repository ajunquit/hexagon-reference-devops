# Operación de mensajería en Azure Service Bus

Completa la [guía común de operación](operacion-mensajeria.md) para el proveedor `azure-service-bus`.
Sus piezas están en `scripts/AzureServiceBusOperationsPolicy.psm1` y en
`operations/Hexagon.Messaging.Operations/AzureOperations.cs`.

## Política

- `operatorIdentities` usa UUID de principal existentes.
- `notificationTargets` lista Action Groups existentes.
- `oldestMessageAgeSeconds` es `null`: Service Bus no ofrece una métrica nativa de antigüedad por
  suscripción.
- Todas las suscripciones tienen DLQ y, por tanto, umbral y plazo de revisión.

```powershell
pwsh ./scripts/Test-MessagingOperationsPolicy.ps1 `
  -Policy products/hexagon-example/environments/dev/messaging-operations-policy.json `
  -TopologyPolicy products/hexagon-example/environments/dev/azure-service-bus-policy.json
```

## Alertas

Azure crea alertas por topic `ActiveMessages` y `DeadletteredMessages`, con evaluación cada minuto y
ventana de cinco minutos, umbral mínimo entre consumidores y Action Groups declarados. No presenta
esas métricas como si fueran de suscripción. Para localizar el consumidor se usa la inspección de
cada DLQ. No inventa una métrica nativa de antigüedad por suscripción.

## Retención y cuarentena

La DLQ de Service Bus ignora TTL y conserva los mensajes hasta su retirada deliberada: revisa antes
del plazo y vigila la capacidad.

## Inspección y recuperación

Los destinos usan el namespace público `<namespace>.servicebus.windows.net`. El operador necesita una
identidad con Data Receiver en la suscripción y Data Sender en el topic. La herramienta usa
`DefaultAzureCredential` y no acepta connection strings cloud. Azure no permite limitar Data Receiver
únicamente a la subcola DLQ.

La inspección muestra una muestra acotada de metadatos canónicos, sin el cuerpo ni descripciones de
error libres. La recuperación publica al topic, por lo que puede haber fanout. El ID de transporte es
un hash estable de incidente + `HexagonMessageId`: así evita la deduplicación del envío original y
permite repetir un envío incierto del mismo incidente.

Para emuladores únicamente en `dev`, `-Local` permite una conexión loopback desde
`HEXAGON_OPERATIONS_CONNECTION_STRING`. La prueba de integración acepta las licencias del emulador y
de SQL Server al crear contenedores efímeros.

## Referencias

- [Azure: DLQ y ausencia de TTL](https://learn.microsoft.com/en-us/azure/service-bus-messaging/service-bus-dead-letter-queues).
- [Azure: detección de duplicados por MessageId](https://learn.microsoft.com/en-us/azure/service-bus-messaging/duplicate-detection).
- [Azure: métricas y dimensión EntityName](https://learn.microsoft.com/en-us/azure/service-bus-messaging/monitor-service-bus-reference).
