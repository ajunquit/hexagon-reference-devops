# AWS SNS/SQS

La fase 8 acepta `operations`: alarmas CloudWatch por cola y DLQ opcional, y políticas IAM para roles
operativos existentes. La lectura destructiva se limita a la DLQ y solo se concede al habilitar
recuperación; la aplicación conserva sus permisos. Consulta [operación](../../../../docs/operacion-mensajeria.md).

Módulo de la fase 5. Materializa la topología lógica del backend con semántica nativa de AWS:

- un topic SNS estándar y cifrado por destino lógico;
- una cola SQS estándar y cifrada por Consumer;
- suscripción SNS → SQS con **Raw Message Delivery**;
- filtro por el atributo `EventType` para routing `include`, o sin filtro para `all`;
- policy de cola que permite `sqs:SendMessage` únicamente al topic declarado;
- visibilidad, retención, long polling y settlement por Consumer;
- redrive y DLQ opcionales de forma independiente para cada cola;
- rol publicador limitado a `sns:Publish` en su topic y uso de su clave KMS;
- rol Consumer limitado a recibir, borrar y cambiar visibilidad en su cola;
- bindings no secretos por workload.

La plantilla no crea topics o colas FIFO porque el contrato actual del adaptador no publica
`MessageGroupId`. Presentar FIFO como una opción produciría una topología que el backend no puede
usar correctamente.

Cuando `redrive.enabled = true`, Terraform crea una DLQ dedicada, configura `maxReceiveCount` y
restringe su `RedriveAllowPolicy` a la cola origen. Su retención debe ser mayor que la retención de
la cola origen. Cuando es `false`, no se crea DLQ ni redrive policy. El runtime nunca recibe permisos
sobre la DLQ.

## Pruebas

```powershell
terraform -chdir=terraform/modules/messaging/aws-sns-sqs init -backend=false
terraform -chdir=terraform/modules/messaging/aws-sns-sqs test
```

La prueba usa el proveedor simulado de Terraform: no necesita una cuenta AWS ni crea recursos.
