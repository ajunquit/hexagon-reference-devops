# Motor de inventario y ciclo de ambiente

Este es el **siguiente paso de preparación de 9C**, previo a conectar Genesis/Apocalypse:
contrato EnvironmentInventory v1, control de planes, dependencias, checkpoints y recuperación.
El [ADR 0015](adr/0015-motor-de-ciclo-de-ambiente-con-inventario.md) amplía el diseño del
[ciclo de ambiente](genesis-y-apocalypse.md). No crea un ambiente Azure ni implementa los workflows.

## Qué contiene el inventario

El [ejemplo](../examples/environment-inventory.json) es ficticio e inicial: roots Pending, sin
recursos ni evidencia de ejecución. El [esquema](../contracts/schemas/environment-inventory-v1.schema.json)
rechaza propiedades desconocidas; un inventario real se guarda protegido fuera de Git.

| Sección | Función |
| --- | --- |
| Producto/ambiente/instancia | Selección exacta; nunca se infiere de una rama |
| Target | Tenant, suscripción, identidad, Storage y contenedor del ambiente |
| IaC | Repositorio, commit completo y hash del snapshot que se conservará |
| Descriptor/release/componentes | Identidad de lo entregado; incluye frontend cuando se declara web |
| Roots | Adaptador conocido, grupo propio, key de estado, dependencias y hashes de configuración/inputs |
| Estados y recursos | Intentos, lineage/serial, planes y IDs actuales/históricos con su presencia |

Ephemeral exige un ID como run-12345-1. Sus grupos son
rg-producto-ambiente-run-ID-attempt-hosting/messaging y sus keys incluyen esa instancia. Persistent
usa persistent. No hay fallback de uno al otro. El contenedor pertenece al ambiente y termina en
-dev/-staging/-prod; el motor no crea contenedores ni grupos. El grupo del estado no puede ser un root.
La identidad efímera y sus ámbitos propios deberán aprovisionarse explícitamente en la integración;
el bootstrap persistente no se presenta como aislamiento efímero ya resuelto.

## Comandos disponibles

Desde la raíz DevOps, validar y consultar orden sin credenciales ni consultas cloud:

```powershell
pwsh ./scripts/Test-EnvironmentInventory.ps1 -Inventory ./examples/environment-inventory.json `
  -Environment dev -InstanceId run-12345-1 -Operation Create
pwsh ./scripts/Test-EnvironmentInventory.ps1 -Inventory ./examples/environment-inventory.json `
  -Environment dev -InstanceId run-12345-1 -Operation Destroy
```

El orden es hosting → messaging para alta y messaging → hosting para baja. El grafo se valida:
sin duplicados, ciclos ni dependencias ausentes; los componentes web/backend requieren hosting y
mensajería requiere backend. Si ambos roots existen,
mensajería depende de hosting. El motor admite dos composiciones, sin mezclarlas en un inventario:

- **Azure:** `AzureHosting` y `AzureServiceBus`, con un resource group por root.
- **AWS** ([ADR 0025](adr/0025-ciclo-de-ambiente-en-aws.md)): `AwsHosting` y `AwsSnsSqs`, con un
  target de cuenta, región, rol y bucket de estado, y un **prefijo corto** común a los dos roots. En
  una instancia efímera, el prefijo es una base de 3 a 12 caracteres más `-` y seis caracteres
  hexadecimales del SHA-256 de `<producto>/<ambiente>/<instancia>`; en una persistente, solo la base.
  Ver `examples/environment-inventory-aws.json`.

  Cada recurso se registra como `aws:<cuenta>:<región>:<tipo>:<id>`, con el tipo y el ID de
  Terraform. El motor rechaza:
  - una cuenta o región ajenas;
  - el proveedor OIDC, usuarios y claves IAM;
  - el bucket de estado y el rol de la reserva;
  - en los planes, un ARN de otra cuenta o región y unas etiquetas `hexagon:*` que no sean de la
    instancia.

RabbitMQ sigue sin coordinación del ciclo.

Para crear un inventario privado nuevo, adapta la definición inicial al producto y usa un
directorio existente bajo artifacts/, con permisos restringidos al operador:

```powershell
New-Item -ItemType Directory -Path ./artifacts/environment -Force | Out-Null
pwsh ./scripts/New-EnvironmentInventory.ps1 -Definition ./environment-definition.json `
  -Environment dev -InstanceId run-12345-1 -Output ./artifacts/environment/inventory.json
```

Solo acepta estado inicial limpio y no sobrescribe. WhatIf no escribe ni crea lock/directorios,
devuelve Unverified y exit 2. La selección incompatible devuelve Blocked/1. InventoryCreated/0
solo significa archivo local creado; no acredita infraestructura. El JSON de salida nunca lleva
inputs, cuerpos de aplicación ni respuestas libres de servicios. No añadas credenciales al contrato.

## API del motor

EnvironmentLifecycle.psm1 expone:

- New/Read/Assert-EnvironmentInventory y Get-EnvironmentRootOrder.
- Add-EnvironmentRootPlan: registra binario y JSON, hash del contexto y revisión del inventario.
- Invoke-EnvironmentRootOperation: revisa la aprobación, ejecuta el protocolo y guarda checkpoints.
- Sync-EnvironmentRoot: reconcilia un intento interrumpido con observaciones actuales.
- Set-EnvironmentRootInputs: cambia hashes de inputs/snapshot con revisión optimista, conserva
  historial e invalida el plan del root; la CLI del adaptador conserva el snapshot remoto.

Las funciones que escriben admiten WhatIf: no toman locks ni escriben ni llaman al puerto; no
devuelven un artefacto aplicado. La CLI traduce su propia simulación a Unverified/2.

Cada plan queda ligado a su root, hashes, contexto inmutable y revisión, con vigencia máxima de
24 horas (timestamp Unix, independiente del huso horario). Una actualización del inventario invalida
planes anteriores. Create no admite delete/replacement/import; Destroy no admite create/update ni
borrar IDs que no consten en el inventario. Se rechazan planes incompletos, diferidos o con errores.
El motor no ejecuta comandos proporcionados por JSON y no modifica políticas para forzar una baja.

La confirmación exacta es CREATE/DESTROY producto ambiente instancia; no sustituye revisar el plan.
Antes de retirar un root, sus dependientes deben estar Destroyed. La política DeleteEphemeral
solo se admite en instancias efímeras fuera de prod; cualquier otro caso usa BackupRequired.

## Puerto de integración obligatorio

Las operaciones ejecutables de la biblioteca requieren un scriptblock de código confiable,
inyectado por el [adaptador explícito Terraform/Azure](adaptador-ciclo-azure.md) y **no leído del
JSON ni expuesto como parámetro de la CLI**. El motor no elige uno por defecto. El doble de tests
no se debe usar en workflows reales.

| Acción | Responsabilidad y evidencia exigida |
| --- | --- |
| Preflight | Contrastar identidad/producto/ambiente/instancia, backend y hashes reales del snapshot/config/inputs; verificar que el JSON procede del mismo plan binario mediante terraform show -json |
| Persist | Guardar inventario y snapshot recuperable en almacenamiento duradero y confirmar hash/revisión/destino/key/snapshot exactos; guardar un archivo en el runner no basta |
| DestructionSafety | Verificar quiescencia y, cuando corresponda, respaldo real; devolver hash de evidencia ligado a producto/ambiente/instancia/root |
| Apply | Aplicar exactamente el binario revisado, con locking Terraform; devolver exit code entero 0 solo al finalizar correctamente |
| Observe | Leer estado, lineage/serial, convergencia, ámbito completo y sondas autorizadas de todos los IDs actuales/históricos; informar recursos propios todavía presentes |

El motor compara las respuestas, pero no convierte una afirmación del adaptador en una prueba
independiente. El adaptador deberá obtener y validar esa evidencia en los servicios. No puede limitarse
a devolver verified/durable=true o repetir los hashes del request. Deberá comprobar el snapshot
real, conservarlo sin depender de aplicaciones/CI y validar su extracción y contenido antes de usarlo.
Los hashes fijan bytes; no son autorización ni una firma del proveedor.

## Estado y recuperación

La escritura local es atómica, con flush, lock exclusivo y revisión optimista. Se rechazan enlaces
del inventario/lock y sus directorios. El caller protege permisos y no permite otros escritores
ajenos al protocolo. La integración distribuida deberá añadir lease/CAS remoto y exclusión mutua
común entre Genesis, despliegue y Apocalypse; el lock local no resuelve dos runners.

Antes de Apply se guarda Applying/Destroying y se exige acuse duradero. Si ese acuse falla, no se
ejecuta. Un fallo posterior conserva Failed y el último intento. Si desaparece el runner, el checkpoint
Applying/Destroying debe recuperarse y reconciliarse; no se reutiliza el plan automáticamente.
Sync registra recursos creados parcialmente y conserva Failed si falta convergencia. Después se
prepara y revisa un plan nuevo o se continúa la baja, siguiendo el grafo.

Destroyed requiere estado legible (o ausencia autorizada explícita sin lineage previo), ámbito
accesible y completo, cero recursos propios restantes y sondas Missing de todos los IDs registrados.
Denied/Unknown, estado inaccesible, lineage distinto, serial regresivo o datos parciales bloquean.
Los IDs históricos no se borran para aparentar limpieza; un ID que sale del estado debe comprobarse
ausente. Los grupos y recursos del bootstrap no forman parte de lo retirado.

Verified es el resultado del root según el adaptador confiable; applicationVerified permanece false.
No acredita publicación de SPA, migraciones, salud de API/Workers ni recorrido integral. Los status
de un JSON por sí solos no autorizan operaciones: su procedencia y custodia deben verificarse.

## Evidencia y continuación

Test-EnvironmentLifecycle.ps1 cubre selección, claves efímeras/persistentes, dependencias, planes,
hashes/caducidad, confirmación, preflight, checkpoint duradero, fallo parcial, recuperación, ausencia,
estado inaccesible y evidencia de respaldo. Utiliza un doble del puerto, sin cambios cloud.

El [adaptador Terraform/Azure](adaptador-ciclo-azure.md) incorpora almacenamiento remoto, snapshot
recuperable, lease/CAS y observación, con pruebas de protocolo sin cambios cloud. Las
[reservas efímeras y Genesis/Apocalypse](ciclo-efimero-azure.md) conectan los ámbitos de instancia y
las etapas manuales con diagnóstico real previo a ejecutar. Su adopción necesita el bootstrap
aislado preparado en el producto. Faltan artefactos, migraciones, SPA, salud, recorrido integral
y limpieza automática incluso tras fallos, además de comprobarlo en Azure. 9C sigue abierta.

Referencias: [JSON Terraform](https://developer.hashicorp.com/terraform/internals/json-format),
[planes guardados](https://developer.hashicorp.com/terraform/cli/commands/plan) y
[observación de estado](https://developer.hashicorp.com/terraform/cli/commands/show).
