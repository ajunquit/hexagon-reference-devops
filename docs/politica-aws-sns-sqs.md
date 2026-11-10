# Política de AWS SNS/SQS

Versión vigente: `hexagon.ec/aws-sns-sqs-policy/v1`.

La fase 5 combina el manifiesto lógico del backend con una política física de DevOps:

| Fuente | Dueño | Contenido |
| --- | --- | --- |
| `.hexagon/messaging-requirements.json` | Backend | Destinos, Consumers, workloads, eventos y routing |
| `aws-sns-sqs-policy.json` | DevOps | Región, nombres, visibilidad, retención, roles y redrive por cola |

El materializador exige coincidencia exacta de producto, ambiente, destinos, Consumers y workloads.
También verifica el commit y SHA-256 del manifiesto antes de producir entradas Terraform.

## Ubicación

```text
products/<product>/environments/<environment>/
├── descriptor.json
└── aws-sns-sqs-policy.json
```

El ejemplo está en
[`examples/aws-sns-sqs-policy.json`](../examples/aws-sns-sqs-policy.json). Sus roles y nombres son
ficticios y deben sustituirse en la instancia del producto.

## Decisiones por cola

| Campo | Decisión |
| --- | --- |
| `kmsAliasName` | Alias de la clave KMS administrada por el producto para cifrar topics |
| `queueName` | Nombre físico de la cola SQS estándar |
| `visibilityTimeoutSeconds` | Tiempo durante el cual un mensaje recibido queda oculto |
| `messageRetentionSeconds` | Retención de mensajes en la cola origen |
| `receiveMessageWaitTimeSeconds` | Long polling, entre 0 y 20 segundos |
| `retryVisibilityTimeoutSeconds` | Visibilidad que aplica el Consumer después de un fallo |
| `redrive.enabled` | Si esta cola crea o no una DLQ y redrive policy |
| `redrive.maxReceiveCount` | Recepciones antes de mover el mensaje a la DLQ |
| `redrive.deadLetterQueueName` | Nombre de la DLQ dedicada |
| `redrive.deadLetterMessageRetentionSeconds` | Retención de DLQ, siempre mayor que la cola origen |

`redrive` es explícito incluso cuando está deshabilitado. No existe un valor global que obligue a
todas las colas a tener DLQ.

## Routing y entrega

- SNS entrega el cuerpo sin envoltura mediante Raw Message Delivery.
- El adaptador publica `EventType` como atributo `String`.
- `routing.mode = include` crea un filtro SNS sobre ese atributo.
- `routing.mode = all` no crea filter policy.
- La policy SQS acepta `SendMessage` solo desde el ARN del topic asociado.

El módulo crea únicamente topics y colas estándar. FIFO requeriría que el contrato backend
declarara y publicara `MessageGroupId`; no se simula esa capacidad.

## Identidad y bindings

`workloadRoleNames` mapea cada workload a un IAM role existente y distinto. Terraform añade
políticas inline de mínimo privilegio:

- publicador: `sns:Publish` únicamente en su topic y uso de la clave KMS de mensajería;
- Consumer: Receive/Delete/ChangeVisibility y lectura de atributos únicamente en su cola;
- ningún workload recibe administración de SNS/SQS ni acceso a la DLQ.

Los outputs generan por workload `TopicArn`, `QueueUrl`, `Region` y
`RetryVisibilityTimeoutSeconds`. Las credenciales siguen la cadena estándar de AWS y nunca se
escriben en la política o los bindings.

## Materializar entradas de Terraform

```powershell
pwsh ./scripts/Export-AwsSnsSqsTerraformInputs.ps1 `
  -Descriptor products/hexagon-hr/environments/dev/descriptor.json `
  -Policy products/hexagon-hr/environments/dev/aws-sns-sqs-policy.json `
  -Output terraform/environments/dev/aws/aws-sns-sqs.auto.tfvars.json
```

`-WhatIf` valida las fuentes sin escribir. El archivo generado se ignora en Git.

Para planificar se usa el root AWS del ambiente y un backend S3 configurado externamente:

```powershell
terraform -chdir=terraform/environments/dev/aws init -backend-config=<configuración-protegida>
terraform -chdir=terraform/environments/dev/aws plan
```

El backend usa cifrado KMS, versionado y `use_lockfile = true`. La fase 9 automatizará plan y apply
con identidad federada; no se ejecuta `apply` local contra ambientes compartidos.
