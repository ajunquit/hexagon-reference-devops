# Política de Azure Service Bus

Versión vigente: `hexagon.ec/azure-service-bus-policy/v1`.

La fase 4 combina dos fuentes que tienen dueños distintos:

| Fuente | Dueño | Contenido |
| --- | --- | --- |
| `.hexagon/messaging-requirements.json` | Backend | Destinos, Consumers, workloads, eventos y routing lógicos |
| `azure-service-bus-policy.json` | DevOps | Región, nombres físicos, SKU, TTL, entregas e identidades del ambiente |

La política no duplica el routing ni los workloads del backend. El materializador exige que ambas
fuentes declaren exactamente los mismos destinos y Consumers; también exige un principal para cada
workload. Una diferencia falla antes de ejecutar Terraform.

## Ubicación

```text
products/<product>/environments/<environment>/
├── descriptor.json
└── azure-service-bus-policy.json
```

El ejemplo completo está en
[`examples/azure-service-bus-policy.json`](../examples/azure-service-bus-policy.json). Al copiar su
forma a un producto se cambian todos los nombres y principal IDs ficticios.

## Decisiones por ambiente

| Campo | Decisión |
| --- | --- |
| `location` | Región de Azure |
| `resourceGroupName` | Grupo de recursos del producto y ambiente |
| `namespace.name` | Nombre global del namespace |
| `namespace.sku` | `Standard` o `Premium`; Basic no admite topics |
| `namespace.capacity` | Unidades de mensajería, solo para Premium |
| `namespace.publicNetworkAccessEnabled` | Acceso público del namespace; la identidad sigue siendo obligatoria |
| `destinations[].topicName` | Topic físico del destino lógico |
| `defaultMessageTtl` | Retención activa en formato ISO 8601 |
| `duplicateDetection*` | Detección de duplicados y su ventana |
| `consumers[].subscriptionName` | Suscripción física del Consumer |
| `maxDeliveryCount` | Entregas antes de mover a la DLQ incorporada |
| `lockDuration` | Duración del lock, entre 5 segundos y 5 minutos |
| `deadLetterOnMessageExpiration` | Si un mensaje expirado también va a la DLQ |
| `workloadPrincipalIds` | Object IDs no secretos de las identidades administradas |

`local_auth_enabled` no es una opción: Terraform siempre lo fija en `false`. Las aplicaciones usan
el FQDN del namespace y su identidad. No se generan connection strings, SAS keys ni secretos.

## Materializar entradas de Terraform

Con un descriptor real, fijado a commits y SHA-256 válidos:

```powershell
pwsh ./scripts/Export-AzureServiceBusTerraformInputs.ps1 `
  -Descriptor products/hexagon-hr/environments/dev/descriptor.json `
  -Policy products/hexagon-hr/environments/dev/azure-service-bus-policy.json `
  -Output terraform/environments/dev/azure/azure-service-bus.auto.tfvars.json
```

El script vuelve a descargar y validar todas las fuentes inmutables. El archivo generado se ignora
en Git porque contiene bindings físicos del ambiente, aunque no secretos. `-WhatIf` ejecuta todas
las validaciones sin escribirlo.

Luego puede comprobarse el plan sin aplicar:

```powershell
terraform -chdir=terraform/environments/dev/azure init -backend-config=<configuración-protegida>
terraform -chdir=terraform/environments/dev/azure plan
```

El backend `azurerm` es parcial: su almacenamiento, contenedor, key e identidad se entregan fuera
del repositorio. No se usa estado local para un ambiente compartido. La fase 9 automatizará el plan
y la aplicación con identidad federada, revisión y aprobación; hasta entonces no se ejecuta
`apply` desde una estación local.

## Routing y DLQ

- `all` crea una regla SQL explícita `1=1`.
- `include` crea una regla de correlación por evento, sobre `Subject` (`label` en Terraform).
- la regla `$Default` se elimina para impedir que una suscripción filtrada reciba todo;
- toda suscripción de Azure tiene la ruta `$DeadLetterQueue`; no puede hacerse opcional;
- la DLQ no se limpia sola. Alertas, retención, inspección y reproducción pertenecen a la fase 8.

La API y los Workers nunca reciben `Manage`: el publicador recibe `Data Sender` en su topic y cada
Consumer, `Data Receiver` únicamente en su suscripción.
