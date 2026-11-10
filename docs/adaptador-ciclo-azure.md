# Adaptador Terraform/Azure del ciclo de ambiente

Este bloque de 9C conecta el [motor de inventario](motor-ciclo-ambiente.md) con Terraform y las
API de Azure, según el [ADR 0016](adr/0016-adaptador-azure-y-custodia-remota-del-inventario.md).
Incluye snapshots recuperables, almacenamiento Blob, exclusión distribuida y observación del
proveedor. Se conecta mediante [Genesis/Apocalypse y reservas efímeras](ciclo-efimero-azure.md);
el despliegue de aplicaciones es trabajo posterior. `applicationVerified`
permanece `false`: verificar un root no demuestra que frontend/backend estén operativos.

## Preparación y límites

- Usa Terraform >= 1.10 y < 2; el snapshot fija la versión exacta. CI usa 1.17.1. Conserva los locks
  de proveedores y ejecuta `init -lockfile=readonly` con un archivo CLI controlado.
- Requiere una sesión Azure CLI de service principal federado, con tenant, suscripción y client ID
  exactos. Rechaza credenciales ARM y argumentos Terraform ambientales que cambien la ejecución.
  Los tokens se mantienen en memoria; no se imprimen respuestas, inputs, planes ni estado.
- El bootstrap debe haber creado el Storage/contenedor y los grupos propios con sus tags, una
  identidad de instancia y sus permisos acotados. En una instancia efímera también se exige el tag
  `instance`. El bootstrap persistente de dev **no resuelve** esa identidad efímera. Aprovisionarla
  y sus límites corresponden a la reserva Terraform descrita en la guía del ciclo; este adaptador
  de workloads no crea esos recursos.
- Antes de escribir en Blob, la CLI contrasta la cuenta y consulta los grupos y roles retenidos del
  bootstrap. Conserva Contributor y RBAC Administrator de esa identidad, con la condición de
  delegación esperada. Conserva los roles heredados de otros principales y rechaza asignaciones
  heredadas directas y roles adicionales de la identidad de ejecución. No sustituye la auditoría de permisos del bootstrap
  ni comprueba membresías indirectas de grupos en Entra.
- Los roots admitidos son hosting Azure y Service Bus; rutas y tipos de recursos se fijan en código.
  AWS/RabbitMQ conservan sus adaptadores separados, pendientes de este ciclo cloud.
- Los inputs proceden de los exportadores de hosting/mensajería y contienen bindings públicos y
  referencias a secretos. No introduzcas credenciales en ellos. La detección de claves conocidas
  es un guardrail adicional, no un detector universal de secretos. Planes y estado se tratan como
  datos sensibles y quedan fuera de Git, logs y artefactos públicos.

`Apply` exige GitHub Actions, `workflow_dispatch`, `refs/heads/main`, el repositorio del inventario
y `genesis.yml` o `apocalypse.yml` de main. Esas entradas ya conectan OIDC, Environments protegidos
y checkout confiable. No se permite ejecutar apply local contra ambientes compartidos;
las variables de entorno por sí solas no son autenticación.

## Snapshot y custodia

`EnvironmentSnapshot` v1 guarda los `.tf`, locks e inputs de los roots seleccionados, un manifiesto
con SHA-256 por archivo, commit y versión Terraform. Se construye desde **objetos Git** del commit
registrado, no desde archivos de trabajo. El commit debe ser ancestro del main confiable local y
el origin debe coincidir con el repositorio del inventario. Los runners deben descargar el historial
necesario y actualizar `origin/main` desde una fuente confiable antes de invocar la CLI.

La recuperación verifica nuevamente los bytes Terraform contra ese Git confiable. Un blob alterado,
aunque también se haya cambiado su checksum, no autoriza código distinto. Se rechazan rutas que
escapan del ZIP, duplicados, symlinks y archivos/cantidades fuera de los límites. El workspace se
crea privado bajo `artifacts/`, con ACL del usuario en Windows o modo 700 en Unix. No reutilices un
workspace de origen desconocido ni ejecutes procesos ajenos bajo la misma identidad del runner.

Por producto/ambiente/instancia se conservan:

```text
<product>/<environment>/<instance>/
  control.json
  inventory.json
  snapshots/<sha256>.zip
  plans/<reviewSha256>/<root>.tfplan
  plans/<reviewSha256>/<root>.json
  evidence/<sha256>.json
  hosting.tfstate
  messaging.tfstate
```

Un lease infinito de `control.json` serializa las operaciones del protocolo; se comprueba su
propiedad antes de escribir y durante los procesos Terraform. La pérdida del lease detiene el
proceso. Terraform conserva además su locking de estado. Los snapshots y planes son inmutables:
PUT condicional y lectura de confirmación. El inventario usa ETag/If-Match, revisión consecutiva y
lectura del hash/revisión escritos. Un fallo no acredita persistencia ni permite continuar Apply.

El lease coordina clientes que siguen este protocolo; no impide que un administrador altere otros
blobs. Restringe RBAC, conserva cifrado, versionado, recuperación y retención del bootstrap.
Despliegue y baja deberán compartir este mismo control de concurrencia.

## Secuencia de comandos

Desde la instancia DevOps, con definición inicial, inputs reales y destinos autorizados:

```powershell
# Local: fija código/configuración/inputs y crea el workspace privado.
pwsh ./scripts/Invoke-AzureEnvironment.ps1 -Mode Build `
  -Inventory ./environment-definition.json -Environment dev -InstanceId run-12345-1 `
  -InputDirectory ./artifacts/exported-inputs -Workspace ./artifacts/run-12345-1

# Cloud: valida destino y conserva snapshot/inventario antes de Terraform.
pwsh ./scripts/Invoke-AzureEnvironment.ps1 -Mode Initialize `
  -Inventory ./artifacts/run-12345-1/inventory.json -Environment dev -InstanceId run-12345-1 `
  -Workspace ./artifacts/run-12345-1

pwsh ./scripts/Invoke-AzureEnvironment.ps1 -Mode Prepare -RootId hosting -Operation Create `
  -Inventory ./artifacts/run-12345-1/inventory.json -Environment dev -InstanceId run-12345-1 `
  -Workspace ./artifacts/run-12345-1
```

`Prepare` conserva binario y JSON; devuelve `reviewSha256`. Solo prepara: no aplica recursos.
La futura entrada confiable ejecutará `Apply` con ese hash y la confirmación exacta
`CREATE hexagon-product dev run-12345-1` (o `DESTROY ...`). No ejecutes los ejemplos ficticios
contra una cuenta. `-WhatIf` devuelve `Unverified`/2 sin credenciales, consultas cloud ni escrituras.
Built/Initialized/Prepared/Restored/InputsUpdated tienen exit 0, pero no acreditan un root operativo.
Blocked/Failed devuelven 1. La salida sigue `AzureEnvironmentResult` v1 y solo contiene metadatos.

Una vez observadas las identidades de hosting, exporta los inputs de mensajería con esos IDs y usa:

```powershell
pwsh ./scripts/Invoke-AzureEnvironment.ps1 -Mode UpdateInputs -RootId messaging `
  -Inventory ./artifacts/run-12345-1/inventory.json -Environment dev -InstanceId run-12345-1 `
  -InputDirectory ./artifacts/exported-inputs -Workspace ./artifacts/run-12345-1
```

El directorio contiene los inputs de **todos** los roots. Solo puede cambiar el root seleccionado;
configuración y commit se conservan. Publica un snapshot nuevo, aumenta la revisión, retira el plan
del root cambiado y conserva IDs/lineage/serial. Los planes anteriores dejan de ser aprobaciones
vigentes; prepara/revisa uno nuevo. También permite activar las etapas de hosting después de
publicar imágenes y completar jobs. No sincroniza automáticamente valores ni ejecuta aplicaciones.

## Fallos, recuperación y baja

Si el runner falla, conserva el inventario remoto. En otro runner confiable, usa la definición
como localizador del mismo producto/ambiente/instancia y un workspace nuevo:

```powershell
pwsh ./scripts/Invoke-AzureEnvironment.ps1 -Mode Restore `
  -Inventory ./environment-definition.json -Environment dev -InstanceId run-12345-1 `
  -Workspace ./artifacts/recovery-run-12345-1
pwsh ./scripts/Invoke-AzureEnvironment.ps1 -Mode Sync -RootId hosting `
  -Inventory ./artifacts/recovery-run-12345-1/inventory.json -Environment dev -InstanceId run-12345-1 `
  -Workspace ./artifacts/recovery-run-12345-1
```

Restore recupera snapshot e inventario de Blob; Apply recupera su plan por hash cuando corresponda.
No necesita artefactos/CI de aplicaciones. Sí necesita el historial Git confiable de DevOps, la
versión Terraform registrada y los proveedores fijados. Un inventario local atrasado se bloquea y
debe recuperarse; no se sobrescribe el remoto con una copia antigua. Sync consulta el proveedor;
no repite un Apply ni declara ausencia por un 403/timeout.

Si el proceso murió dejando un lease infinito, **no hay ruptura automática**. El operador identifica
la ejecución y confirma que terminó y que no queda Terraform activo antes de romper el lease del
`control.json` exacto mediante las herramientas Azure. Después debe Restore/Sync y revisar un plan
nuevo. No uses `force-unlock` ni rompas un lease por el mero transcurso de tiempo. Si el unlock fue
necesario, registra el incidente fuera de los blobs técnicos sin copiar credenciales o estado.

La observación lee el estado v4 con su ETag, lineage/serial y recursos; consulta grupos, recursos,
roles y cada ID actual/histórico, y contrasta que el estado no cambió durante la lectura. Create
exige además `terraform plan -detailed-exitcode` sin cambios. Destroy requiere estado vacío,
enumeración completa y sondas 404 de todos los IDs registrados. Una baja aún visible se conserva
como Failed: espera y vuelve a Sync; no hay reintento ciego ni borrado del historial.

La baja efímera exige `DeleteEphemeral` fuera de prod. DestructionSafety **observa** quiescencia: revisiones
Container Apps inactivas, jobs terminados y topics/suscripciones Service Bus deshabilitados. No
pausa aplicaciones ni cambia topología mediante ARM; la operación explícita Quiesce de Apocalypse
realiza esa preparación mediante comandos Azure CLI acotados y vuelve a observarla. Invalida planes
anteriores y guarda evidencia técnica ligada a la instancia. `BackupRequired` se bloquea hasta
implementar un verificador de respaldos reales en la adopción persistente de 9D.

## Evidencia de esta entrega

`Test-AzureEnvironmentAdapter.ps1` usa Git real, ZIPs y un plan/show Terraform local sin apply.
Prueba leases, CAS, hashes, destinos, roles protegidos, consultas denegadas, creación/baja,
quiescencia y recuperación con un `HttpMessageHandler` simulado y ejecución Terraform cloud
simulada. No acredita acceso a Azure ni una ejecución integral. `Test-Repository.ps1` la incluye.

Las reservas efímeras y workflows están implementados según la guía del ciclo. Pendientes de 9C: entrega de artefactos,
migraciones, bindings, publicación/validación de la SPA y recorrido navegador → API/Worker real,
limpieza incluso tras fallos y verificación contra una cuenta autorizada.

Referencias: [lease Blob](https://learn.microsoft.com/en-us/rest/api/storageservices/lease-blob),
[escrituras condicionales](https://learn.microsoft.com/en-us/rest/api/storageservices/specifying-conditional-headers-for-blob-service-operations),
[roles del grupo y heredados](https://learn.microsoft.com/en-us/rest/api/authorization/role-assignments/list-for-resource-group?view=rest-authorization-2022-04-01),
[plan Terraform](https://developer.hashicorp.com/terraform/cli/commands/plan) y
[formato de estado/plan](https://developer.hashicorp.com/terraform/internals/json-format).
