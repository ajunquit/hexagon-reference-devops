# Política de RabbitMQ

Versión vigente: `hexagon.ec/rabbitmq-policy/v1`.

La fase 6 combina el manifiesto lógico del backend con una política física de DevOps:

| Fuente | Dueño | Contenido |
| --- | --- | --- |
| `.hexagon/messaging-requirements.json` | Backend | Destinos, Consumers, workloads, eventos y routing |
| `rabbitmq-policy.json` | DevOps | Virtual host, nombres, límite, usuarios y DLX/DLQ por cola |

El materializador exige coincidencia exacta de producto, ambiente, destinos, Consumers y workloads.
También verifica el commit y `SHA-256` del manifiesto antes de producir entradas Terraform.

## Ubicación

```text
products/<product>/environments/<environment>/
├── descriptor.json
└── rabbitmq-policy.json
```

El ejemplo está en [`examples/rabbitmq-policy.json`](../examples/rabbitmq-policy.json). Sus nombres
y usuarios son ficticios y deben sustituirse en la instancia del producto.

## Decisiones por cola

| Campo | Decisión |
| --- | --- |
| `virtualHost` | Virtual host dedicado al producto y ambiente |
| `destinations[].exchangeName` | Exchange `topic` durable del destino lógico |
| `consumers[].queueName` | Cola quorum durable del Consumer |
| `consumers[].deliveryLimit` | Redeliveries máximas antes de dead-letter o descarte |
| `deadLetter.enabled` | Si esta cola crea o no DLX y DLQ |
| `deadLetter.exchangeName` | Exchange `direct` dedicado cuando se habilita |
| `deadLetter.queueName` | DLQ quorum dedicada cuando se habilita |
| `deadLetter.routingKey` | Routing key exacta entre DLX y DLQ |
| `workloadUserNames` | Usuario preexistente y distinto por workload |

`deadLetter` es explícito incluso cuando está deshabilitado. No existe una decisión global que
obligue a todas las colas a tener DLQ. Si una cola supera `deliveryLimit` sin DLQ, RabbitMQ descarta
el mensaje; esa consecuencia debe revisarse al aprobar la política.

## Routing, entrega y permisos

- `routing.mode = all` crea un binding `#`.
- `routing.mode = include` crea un binding exacto por tipo de evento.
- los publicadores solo escriben en sus exchanges y routing keys declaradas;
- los Consumers solo leen sus colas fuente;
- `configure = ^$` impide que el runtime cree o cambie topología;
- ningún workload recibe acceso a una DLQ.

Las colas fuente y DLQ son quorum. Cuando se habilita DLQ, la policy usa dead-lettering
`at-least-once` y `overflow = reject-publish`. El inbox del backend conserva la idempotencia ante
duplicados.

## Usuarios y secretos

Los usuarios de `workloadUserNames` deben existir antes del `apply`. El módulo no usa
`rabbitmq_user`, porque el proveedor guarda su contraseña en texto plano dentro del estado.
Terraform administra los permisos; el gestor de secretos del despliegue entrega una connection
string distinta por workload en las claves indicadas por
`workload_connection_requirements`.

Las credenciales administrativas del proveedor se inyectan como variables efímeras:

```powershell
$env:TF_VAR_rabbitmq_management_endpoint = 'https://rabbitmq.example:15671'
$env:TF_VAR_rabbitmq_management_username = '<secret-reference>'
$env:TF_VAR_rabbitmq_management_password = '<secret-reference>'
```

Los valores reales proceden del gestor de secretos; no se escriben en archivos ni comandos
versionados. Terraform 1.10 omite las variables `ephemeral` del estado y de los planes.

## Materializar entradas de Terraform

```powershell
pwsh ./scripts/Export-RabbitMqTerraformInputs.ps1 `
  -Descriptor products/hexagon-hr/environments/dev/descriptor.json `
  -Policy products/hexagon-hr/environments/dev/rabbitmq-policy.json `
  -Output terraform/environments/dev/rabbitmq/rabbitmq.auto.tfvars.json
```

`-WhatIf` valida las fuentes sin escribir. El archivo generado se ignora en Git y no contiene
secretos.

El root usa el backend HTTP genérico para no acoplar RabbitMQ a Azure o AWS. La automatización debe
inyectar una URL HTTPS y endpoints de lock mediante `TF_HTTP_ADDRESS`, `TF_HTTP_LOCK_ADDRESS` y
`TF_HTTP_UNLOCK_ADDRESS`; las credenciales usan `TF_HTTP_USERNAME` y `TF_HTTP_PASSWORD`.

```powershell
terraform -chdir=terraform/environments/dev/rabbitmq init
terraform -chdir=terraform/environments/dev/rabbitmq plan
```

La fase 9 automatizará plan y apply. Hasta entonces no se ejecuta `apply` local contra ambientes
compartidos.
