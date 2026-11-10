# Bootstrap de plataformas: ejecución y verificación

El bootstrap prepara **GitHub Actions → Azure** antes de Genesis. El comando valida el YAML,
materializa planes por etapa, aplica únicamente lo revisado, migra el estado y verifica la
configuración y el diagnóstico federado. Terraform conserva la propiedad de la infraestructura;
PowerShell coordina y configura GitHub. Véanse [ADR 0013](adr/0013-bootstrap-de-plataformas-declarativo.md)
y [ADR 0014](adr/0014-bootstrap-ejecutable-con-aislamiento-por-ambiente.md).

**Implementación no significa plataforma aprovisionada.** El ejemplo contiene valores ficticios;
CI prueba con dobles y mocks. No hay evidencia cloud de un producto hasta ejecutar su recorrido y
obtener `Verified`. Este bloque no implementa Genesis/Apocalypse ni el despliegue completo de 9C.

## Definición y precondiciones

Copia [platform-bootstrap.yaml](../examples/platform-bootstrap.yaml) a
`.config/platform-bootstrap.yaml` de la instancia DevOps y sustituye sus valores ficticios.
Confirma el YAML en main antes del diagnóstico. No contiene secretos ni comandos libres.
`product` coincide con `.config/product.json`, el repositorio es `<owner>/<product>-devops` y la
rama confiable es main. Se rechazan propiedades desconocidas, duplicados, tags, anchors/aliases,
múltiples documentos, IDs nulos e identidades/grupos compartidos. UTF-8, máximo 64 KiB y profundidad
acotada. Los errores no muestran valores rechazados.

Requisitos:

- PowerShell 7, SDK de `global.json`, Terraform `>=1.10,<2`, Azure CLI y GitHub CLI.
- Bootstrap usa la sesión Azure CLI revisada. Se rechazan `TF_CLI_ARGS*`, `TF_DATA_DIR`, workspaces
  Terraform alternativos y credenciales `ARM_*` que sustituyan esa sesión; tenant y suscripción
  llegan explícitamente del YAML. El workspace queda ligado al producto/repositorio/destino/Storage.
- Sesiones `az` y `gh` del operador autorizado. Se comprueban tenant/suscripción **antes de las
  demás consultas y antes de crear archivos de ejecución**; luego repositorio, acceso administrativo,
  Actions, subject OIDC y ownership. Una denegación no equivale a recurso ausente.
- Operador Azure con autoridad previa para crear el grupo persistente y los grupos declarados,
  Storage/identidades y asignar los roles declarados. No reutiliza el token de lectura del core.
  El plan State incluye `Storage Blob Data Contributor` sobre ese almacenamiento para el operador
  actual, necesario para la migración. Debe revisarse ese principal; no amplía su autoridad de
  administración ni concede acceso a una identidad de workload. Espera propagación si Azure
  todavía deniega el acceso de datos tras Apply. No habilites claves compartidas.
- Proveedores Azure requeridos previamente registrados por la plataforma: para bootstrap,
  Microsoft.Storage y Microsoft.ManagedIdentity. Se deshabilita el registro automático del provider;
  los futuros workloads requieren sus propios proveedores registrados.
- GitHub: acceso administrativo y permisos para Environments/protecciones, variables de ambiente y
  configuración de Actions. El diagnóstico manual requiere Actions write para iniciarlo. No amplíes
  `HEXAGON_CORE_READ_TOKEN`; usa una sesión o credencial administrativa separada, fuera de archivos.
- El plan de GitHub de la cuenta debe soportar revisores/protecciones en el tipo de repositorio.
  Si no los admite, la escritura falla y el resultado queda Blocked; no se elimina el gate de prod
  como alternativa. Los revisores deben existir y tener acceso al repositorio.

El lector usa YamlDotNet 18.1.0. La primera compilación puede restaurar NuGet público; offline
significa sin consultas Azure/GitHub, no ausencia de cachés locales `bin/obj`.

## Propiedad y aislamiento

| Etapa | Propietario y recursos |
| --- | --- |
| State | Terraform `bootstrap/azure`: Storage, contenedor bootstrap, tres contenedores de ambiente, lock y grupos persistentes de ambiente |
| Access | Terraform `bootstrap/azure-access`: tres identidades administradas, federación por Environment y asignaciones RBAC |
| GitHub | API GitHub: Environments, main como única rama, revisores, prohibición de autoaprobación, bypass administrativo deshabilitado y variables Azure |

Las identidades viven en el grupo persistente. Cada una tiene Contributor **solo en sus grupos**,
Storage Blob Data Contributor **solo en su contenedor** y delegación RBAC condicionada en sus grupos:
solo ServicePrincipal y los roles AcrPull, Key Vault Secrets User, Service Bus Data Sender/Receiver.
La condición restringe escritura y borrado; no permite delegar Owner, Contributor ni roles de
administración. No existen contraseñas ni certificados creados por este recorrido: usa identidades
administradas, no una aplicación Entra con credenciales estáticas. El adaptador Azure DevOps/WIF
sigue pendiente y no se afirma haber comprobado sus credenciales.

El contenedor YAML, por ejemplo `tfstate`, queda para bootstrap; los ambientes usan `tfstate-dev`,
`tfstate-staging` y `tfstate-prod`. Los nombres derivados deben caber en 63 caracteres. Separar claves
dentro del mismo contenedor no se considera aislamiento. Los estados bootstrap se guardan en
`<product>/bootstrap/state.tfstate` y `<product>/bootstrap/access.tfstate`.

Los roots de hosting y mensajería consultan los grupos como datos; **no los crean ni destruyen**.
Los grupos, Storage, identidades y RBAC de bootstrap sobreviven a Apocalypse. Apocalypse retirará
los recursos interiores y los estados de workloads según su inventario, nunca estos límites.

## Validar y revisar el recorrido sin ejecutar

Desde la raíz DevOps:

```powershell
pwsh ./scripts/Invoke-PlatformBootstrap.ps1 -Definition ./.config/platform-bootstrap.yaml -Mode Validate
pwsh ./scripts/Invoke-PlatformBootstrap.ps1 -Definition ./.config/platform-bootstrap.yaml -Mode Plan -Offline
pwsh ./scripts/Invoke-PlatformBootstrap.ps1 -Definition ./.config/platform-bootstrap.yaml -Mode Plan
```

Estos modos conservan `PlatformBootstrapResult` v1: Validated/Planned (exit 0), Unverified (exit 2)
y Invalid/Blocked (exit 1). Siempre `readyToApply=false`, `applyImplemented=false`: describen el
recorrido lógico; no representan un plan binario ejecutable. Plan conectado conserva Inspect para
recursos cuya existencia no acredita su configuración completa. Offline no requiere padres existentes.
`-Output` exporta este resultado a un archivo nuevo, sin sobrescribir; WhatIf evita esa exportación.

## Preparar y aplicar por etapa

Usa un workspace persistente y privado **bajo artifacts/**, fuera de Git. No lo borres ni lo cambies
entre etapas. El runner rechaza enlaces/junctions y toma un lock exclusivo del workspace; en Unix
limita sus permisos al usuario. Solo admite el enlace de instalación del provider azurerm con la
estructura de caché de Terraform; el lockfile revisado fija sus checksums. Los enlaces de configuración,
estado, directorios de etapa o del workspace siguen prohibidos. En Windows usa ACL limitada al operador y disco
cifrado. Los planes, estados temporales y respuestas de planificación pueden ser sensibles.

```powershell
$definition = './.config/platform-bootstrap.yaml'
$workspace = './artifacts/platform-bootstrap'
pwsh ./scripts/Invoke-PlatformBootstrap.ps1 -Definition $definition -Mode Prepare -Stage State -Workspace $workspace
```

Revisa `state/review.plan.json`, los `.tf`, inputs y backend generados. El JSON de respuesta incluye
`details.reviewSha256`. Después de revisar, pásalo explícitamente:

```powershell
pwsh ./scripts/Invoke-PlatformBootstrap.ps1 -Definition $definition -Mode Apply -Stage State -Workspace $workspace -ReviewSha256 '<hash-revisado>'
pwsh ./scripts/Invoke-PlatformBootstrap.ps1 -Definition $definition -Mode Migrate -Stage State -Workspace $workspace
pwsh ./scripts/Invoke-PlatformBootstrap.ps1 -Definition $definition -Mode Prepare -Stage Access -Workspace $workspace
# Revisa access/review.plan.json y usa el hash de esa etapa.
pwsh ./scripts/Invoke-PlatformBootstrap.ps1 -Definition $definition -Mode Apply -Stage Access -Workspace $workspace -ReviewSha256 '<hash-access-revisado>'
pwsh ./scripts/Invoke-PlatformBootstrap.ps1 -Definition $definition -Mode Prepare -Stage GitHub -Workspace $workspace
# Revisa github/github.json: configuración previa y deseada.
pwsh ./scripts/Invoke-PlatformBootstrap.ps1 -Definition $definition -Mode Apply -Stage GitHub -Workspace $workspace -ReviewSha256 '<hash-github-revisado>'
```

Apply verifica SHA-256 del YAML, código/configuración y archivos, repositorio inmutable, subject
observado y vigencia máxima de 24 horas. Repite el preflight. Un archivo alterado, configuración
extra, plan destructivo, estado Terraform cambiado o snapshot GitHub distinto bloquea. La edad se
valida sin depender del huso horario del operador. El hash es una aprobación explícita del plan,
no una firma ni autorización IAM. Protege el workspace frente a otros procesos/usuarios.

Prepare restaura providers con lockfile readonly y crea un plan binario. Apply aplica ese archivo;
no recalcula ni usa `-auto-approve`. No elimina recursos ni resuelve reemplazos automáticamente.
Después de cambios o una aplicación parcial, ejecuta **Prepare de nuevo** y revisa su nuevo hash;
no reutilices el plan anterior. Terraform detecta el estado desactualizado y mantiene el locking.

La etapa GitHub configura prod antes de conceder variables de despliegue. Los valores existentes
iguales no se reescriben y main no se duplica. No borra políticas de rama ajenas: una política adicional,
tag permitido o regla de protección desconocida bloquea para que el operador la resuelva de forma
explícita. Una escritura parcial no se presenta como Applied; se descubre y reconcilia en Prepare.

`-WhatIf` en los modos de ejecución realiza el preflight de lectura y devuelve Unverified sin crear
workspace, lock, plan ni cambios externos. No promete simular una migración o un Apply completo.

## Migración y recuperación

State empieza con backend local dentro de su workspace; Access solo comienza tras la migración.
Migrate configura un backend remoto separado y usa `terraform state push` **sin force**. Conserva
locking y verifica lineage, serial y recursos antes de cambiar el backend original. Si ya hay un
blob remoto, lo contrasta y no lo sobrescribe. Comprueba de nuevo el backend original y solo entonces
elimina `terraform.tfstate` y su backup conocidos. Conserva la copia local ante cualquier fallo.
Una segunda migración contrasta lineage y no vuelve a publicar el estado.

Si se interrumpe una etapa, conserva el workspace: corrige acceso/propagación, vuelve a Prepare
para planes pendientes o repite Migrate si falló la transferencia. Si el estado remoto es ajeno o
más reciente, detente y reconcilia las copias con un operador; nunca uses `-force` ni borres el blob.
La pérdida completa del workspace requiere reconstruir su configuración desde las fuentes fijadas
y recuperar los estados remotos en un procedimiento revisado; no es una importación automática.

**Instalaciones anteriores:** los grupos que todavía pertenezcan al estado de un workload no pueden
pasar a bootstrap mediante un apply directo. Detén los despliegues, respalda los estados, revisa una
migración `state rm`/`import` de los mismos IDs y verifica que los planes no destruyan ni recreen los
grupos. Este comando no adopta recursos preexistentes ni ejecuta esa transferencia por su cuenta.

## Verificación y diagnóstico real

```powershell
pwsh ./scripts/Invoke-PlatformBootstrap.ps1 -Definition $definition -Mode Verify -Workspace $workspace
```

Verify exige ambos estados remotos, configuración confiable y planes Terraform **sin cambios**.
Contrasta identidad/tenant, un único vínculo federado con issuer/subject/audiencia exactos, los roles
directos/heredados observados y sus condiciones, variables GitHub, main y revisores/protecciones.
Una asignación extra en la suscripción observada bloquea. No certifica permisos en otros tenants o
suscripciones fuera del alcance declarado. Sin diagnóstico real devuelve Unverified (exit 2).

Una vez fusionado el workflow, con el YAML real confirmado en main, el operador inicia:

```powershell
$hash = (Get-FileHash $definition -Algorithm SHA256).Hash.ToLowerInvariant()
gh workflow run platform-diagnostic.yml --ref main -f definition=.config/platform-bootstrap.yaml -f definition_sha256=$hash
# Obtén el ID de esa ejecución; espera sus aprobaciones y su finalización.
pwsh ./scripts/Invoke-PlatformBootstrap.ps1 -Definition $definition -Mode Verify -Workspace $workspace -DiagnosticRunId <id>
```

El workflow **Platform Federation Diagnostic** usa tres jobs y los Environments dev/staging/prod,
OIDC con audiencia explícita y actions fijadas por commit. Solo main admite autenticación. Comprueba
lectura de grupos/estado propios y rechazo **403** para grupos/estado de los demás ambientes y
estado de bootstrap. Un 404 no demuestra aislamiento. No crea recursos ni publica tokens/cuerpos.

Verify exige `success` en ejecución, tres jobs y todos los pasos obligatorios; también repositorio,
workflow, main, commit del checkout local y hash del YAML en el título generado. Rechaza canceled,
skipped, neutral, timeout, respuestas parciales y fuentes locales alteradas. Una ejecución de otro
YAML/commit no sirve como evidencia. No inicia workflows automáticamente.

Los modos nuevos devuelven `PlatformBootstrapExecution` v1:

| Estado / exit | Evidencia |
| --- | --- |
| Prepared / 0 | Plan revisable de una etapa; readyToApply=true solo para esa etapa |
| Applied / 0 | Esa etapa terminó; no acredita el bootstrap completo |
| Migrated / 0 | Estado local contrastado con el remoto |
| Verified / 0 | Configuración comprobada y diagnóstico real satisfactorio; platformVerified=true |
| Unverified / 2 | WhatIf o diagnóstico real pendiente |
| Blocked / 1 | Precondición, plan, permisos o evidencia insuficiente |

## Cobertura y referencias

La suite combina YAML/preflight, dobles del transporte/ejecución, pruebas de recuperación y mocks
Terraform y una transferencia contra backend local real, sin apply ni providers externos. Cubre
entorno vacío, target equivocado antes de escribir, planes alterados/caducados,
ausencia de permisos, respuestas parciales, segunda ejecución, migración fallida/estado ajeno,
GitHub parcial, audiencia errónea, permisos extra y diagnóstico cancelado/omitido. No equivale a
haber ejecutado el bootstrap cloud del producto; esa evidencia queda explícita en Verify.

Se adaptó la secuencia de [movieops, commit ba19968](https://github.com/ajunquit/movieops/tree/ba199682b7366600f004c868d9f7b2f6575b641a/scripts)
y se corrigieron sus cinco límites. Azure DevOps/Service Connections no forman parte de este adaptador.
Referencias primarias: [federación Terraform](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/federated_identity_credential),
[delegación RBAC condicionada](https://learn.microsoft.com/en-us/azure/role-based-access-control/delegate-role-assignments-overview),
[Environments](https://docs.github.com/en/rest/deployments/environments),
[políticas de rama](https://docs.github.com/en/rest/deployments/branch-policies) y
[disponibilidad de protecciones](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/review-deployments).
