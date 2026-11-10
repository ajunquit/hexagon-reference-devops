# Desarrollo local de mensajería

Esta carpeta es la frontera local de la topología de mensajería. DevOps lee el manifiesto lógico
`.hexagon/messaging-requirements.json` del backend, genera la definición del proveedor elegido,
levanta el broker con Docker Compose y entrega al AppHost un archivo de bindings por workload.

El AppHost sigue orquestando PostgreSQL, Keycloak, la API y los Workers, pero no crea topics,
suscripciones, colas, exchanges, DLQ o DLX. Los archivos bajo `local/generated/` y el binding que se
escribe en el backend son artefactos locales ignorados por Git.

## Arrancar

Desde la instancia DevOps del producto:

```powershell
pwsh ./scripts/Start-LocalMessaging.ps1 `
  -BackendPath ../hexagon-hr-dotnet-ml `
  -Policy local/policies/hexagon-hr/azure-service-bus-policy.json `
  -AcceptLicense
```

`-AcceptLicense` se usa solo con Azure Service Bus y acepta los términos del emulador y SQL Server.
Para AWS o RabbitMQ se omite. `-Policy` es opcional: cuando se proporciona, la topología local usa
los nombres, reintentos y la elección de DLQ/DLX por cola definidos por DevOps. Sin política se
generan nombres lógicos, tres entregas locales y ninguna DLQ opcional; Azure conserva su DLQ
intrínseca por suscripción.

Azure Emulator admite TTL de hasta **una hora**. Si una política cloud declara un plazo mayor,
la generación falla antes de escribir archivos: crea una política local explícita bajo
`local/policies/<producto>/azure-service-bus-policy.json`, con el esquema v1 y environment dev, y usa
`defaultMessageTtl: PT1H` o un plazo inferior en cada topic/suscripción. No se truncan silenciosamente
los valores cloud. La prueba `-UseExamplePolicy` adapta únicamente su copia temporal a ese límite,
conservando el ejemplo versionado y las demás decisiones por consumidor. El emulador 2.0 también
limita la ventana de detección de duplicados a **cinco minutos**: el generador rechaza un valor
mayor y la copia de prueba fija `duplicateDetectionHistory: PT5M`. Estos límites no cambian las
políticas de los recursos cloud.
La [limitación está documentada por Microsoft](https://learn.microsoft.com/en-us/azure/service-bus-messaging/overview-emulator).

Después, desde el backend:

```powershell
aspire run
```

El primer comando genera `.hexagon/local-messaging-bindings.json` dentro del backend. El AppHost lo
valida contra el producto y proveedor seleccionados, y entrega a cada proceso únicamente sus
variables. Se puede cambiar su ubicación con `LocalMessaging:BindingsFile`.

## Generar sin iniciar Docker

```powershell
pwsh ./scripts/New-LocalMessaging.ps1 `
  -BackendPath ../hexagon-hr-dotnet-ml `
  -Policy products/hexagon-hr/environments/dev/rabbitmq-policy.json
```

Este comando permite inspeccionar los archivos deterministas antes de levantar contenedores. Tanto
él como `Start-LocalMessaging.ps1` admiten `-WhatIf`.

## Detener

```powershell
pwsh ./scripts/Stop-LocalMessaging.ps1 `
  -BackendPath ../hexagon-hr-dotnet-ml
```

El comando elimina los contenedores de mensajería de ese producto y su binding local generado. No
borra políticas versionadas, el manifiesto backend ni datos de otros proyectos.

## Proveedores

| Proveedor | Entorno local | Puertos predeterminados |
| --- | --- | --- |
| Azure Service Bus | Emulador oficial y SQL Server | AMQP `5672`, salud `5300` |
| AWS SNS/SQS | LocalStack | gateway `4566` |
| RabbitMQ | RabbitMQ | AMQP `5672` |

Las fixtures de pruebas integrales del backend siguen creando recursos desechables propios. Esa
preparación pertenece al aislamiento de la prueba y no convierte a la API, los Workers o el AppHost
en propietarios de topología.

Para comprobar manualmente un contenedor real y retirarlo al terminar:

```powershell
pwsh ./tests/Test-LocalMessagingRuntime.ps1 -Provider rabbitmq
```

Azure requiere además `-AcceptLicense`. Esta prueba no forma parte del guardrail rápido del
repositorio porque descarga imágenes y necesita Docker. `-UseExamplePolicy` comprueba además la
decisión de DLQ/DLX por cola con la política de ejemplo adaptada al producto de prueba.
