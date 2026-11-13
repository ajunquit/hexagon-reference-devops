# ADR 0025: ciclo de ambiente en AWS

- Estado: aceptada
- Fecha: 2026-11-12

## Contexto

Las [ADR 0012](0012-genesis-y-apocalypse-por-ambiente.md),
[0015](0015-motor-de-ciclo-de-ambiente-con-inventario.md) y
[0017](0017-reservas-efimeras-y-workflows-del-ciclo.md) fijan cómo nace y se retira un ambiente:
Genesis y Apocalypse manuales, con inventario, planes revisados, lease, reserva efímera federada,
sondas de presencia y baja verificable. Solo existe la implementación de Azure. La entrega de
aplicaciones (descargar candidatos, tareas de mantenimiento, rollout, SPA) se apoya en ese ciclo.

D-9A-AWS ya tiene en AWS el módulo de hosting, las raíces por ambiente y el bootstrap de base de datos
([ADR 0023](0023-referencia-de-hosting-en-aws.md), [ADR 0024](0024-credenciales-de-base-de-datos-en-aws.md)).
Para validar HR en AWS (D-9C-AWS) falta el mismo ciclo que en Azure, con las mismas garantías.

## Decisión

**Genesis y Apocalypse son el estándar de toda nube** (decisión del dueño, 2026-11-12): un ambiente
en Azure, en AWS o en otra nube futura nace y se retira solo con esos workflows y sus garantías.

AWS reutiliza el motor y sus reglas: inventario, orden hosting → messaging y su inverso, planes
revisados, checkpoints, reconciliación, `Quiesce` y baja verificable. Cambian los adaptadores:

| Pieza | Azure | AWS |
| --- | --- | --- |
| Estado Terraform | Contenedor por ambiente en Storage | Bucket S3 del bootstrap (`terraform/bootstrap/aws`), key `<producto>/<ambiente>/<instancia>/<root>.tfstate` y `use_lockfile` |
| Inventario, journal y lease | Blobs con lease | Objetos S3 bajo `<producto>/<ambiente>/<instancia>/`. El lease se toma creando `lease.json` con `If-None-Match: *` y tiene caducidad; el journal se escribe con `If-Match` sobre su ETag |
| Identidad de los workflows | Identidad administrada federada con un Environment | Rol IAM con confianza OIDC exacta en `repo:<owner>/<repo>:environment:<env>` (`sts:AssumeRoleWithWebIdentity`) |
| Reserva efímera | Root `azure-ephemeral`: grupos, contenedor, identidad y permisos | Root `aws-ephemeral`: rol de despliegue de la instancia, prefijo de nombres y permisos limitados a sus etiquetas, su prefijo y su prefijo S3. El proveedor OIDC de GitHub es compartido y vive en un root `aws-access` |
| Ámbito de los recursos | Resource group | Cuenta y región, el **prefijo corto** de la instancia y las etiquetas obligatorias `hexagon:product`, `hexagon:environment` y `hexagon:instance` (`default_tags` del proveedor) |
| Sondas de presencia | `GET` de ARM por ID | AWS Cloud Control API (`GetResource`) por tipo CloudFormation e identificador |
| Completitud de la baja | Listado del resource group | Resource Groups Tagging API filtrada por la etiqueta de la instancia, más las sondas de cada ID |
| Mantenimiento | Container Apps Jobs | `ecs:RunTask` y el código de salida de `DescribeTasks` |
| Web | Static Web Apps | Sincronización con S3 e invalidación de CloudFront |

- **Prefijo corto.** El `name_prefix` del hosting AWS admite 19 caracteres, por los límites de
  nombres del ALB y de los target groups, y una instancia como `run-43262836518-1` no cabe junto al
  producto. La política declara una base de hasta 12 caracteres. Un ambiente persistente usa esa base;
  una instancia efímera usa `<base>-<6 hex>`, con los seis primeros caracteres hexadecimales del
  SHA-256 de `<producto>/<ambiente>/<instancia>`. La reserva lo registra y el inventario lo valida;
  las etiquetas conservan los nombres completos.
- **Inventario.** `EnvironmentInventory` v1 admite un target AWS (`accountId`, `region`, `roleArn`,
  `stateBucket`) y los adaptadores `AwsHosting` y `AwsSnsSqs`. Un root AWS declara su prefijo en
  lugar de un resource group. Un recurso se identifica como `aws:<cuenta>:<región>:<tipo>:<id>`,
  con el tipo y el ID de Terraform, que son los que el motor compara en planes y estados. El adaptador
  lo traduce a tipo CloudFormation e identificador de Cloud Control para las sondas. El motor rechaza
  la cuenta o la región ajenas, los ARN de otra cuenta y los recursos sin las etiquetas de la
  instancia.
- **Tipos sin recurso propio en Cloud Control** (por ejemplo, la configuración de cifrado o de
  versionado de un bucket, o un adjunto de política): su presencia la determina el recurso padre,
  declarado en la tabla de correspondencias del adaptador. Un tipo que no está en esa tabla bloquea
  el plan: nunca se supone ausente.
- **Fuera del ámbito siempre:** el proveedor OIDC, el bucket y la clave KMS del estado, y los roles
  y políticas de la reserva. Apocalypse no los retira (ADR 0012).
- **Sin coste fijo nuevo:** S3, Cloud Control y Tagging API no añaden recursos de pago apreciables.

## Consecuencias

- El contrato de inventario y el motor cambian sin romper Azure: sus inventarios siguen siendo
  válidos.
- La entrega AWS reutiliza las etapas de la de Azure (`Artifacts`, `PrepareMaintenance`,
  `Migrations`, `DatabaseAccess`, `PublishWeb`, etc.). Las tareas de base de datos siguen el orden de
  la ADR 0024.
- Cloud Control no cubre todos los tipos de Terraform. La tabla de correspondencias se prueba contra
  los tipos que usan los módulos `hosting/aws` y `messaging/aws-sns-sqs`. Un tipo nuevo en esos
  módulos obliga a ampliarla.
- La consistencia eventual de la Tagging API no acredita ausencia por sí sola: se combina con las
  sondas por ID, y `Unknown` o `AccessDenied` nunca cuentan como ausencia (ADR 0015).
- **Incrementos**, cada uno con pruebas locales o de protocolo y sin desplegar:
  1. Contrato de inventario y motor con target y roots AWS.
  2. Bootstrap `aws-access` (proveedor OIDC) y reserva `aws-ephemeral`, con su diagnóstico de
     aislamiento.
  3. Custodia en S3 (inventario, journal y lease) y adaptador Terraform AWS con sondas.
  4. `genesis.yml` y `apocalypse.yml` con el proveedor que declara la definición.
  5. Entrega AWS: copia OCI a ECR por digest, tareas de mantenimiento, rollout, SPA e invalidación.
  6. Aceptación y `Quiesce` en AWS.
- Desplegar sigue requiriendo una orden expresa del dueño (D-9C-AWS).
