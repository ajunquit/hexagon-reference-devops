# Entrega verificable y activación del backend efímero

Este bloque de 9C conecta los candidatos de CI de 9B con la reserva y el inventario de
[Genesis/Apocalypse](ciclo-efimero-azure.md). `delivery.yml` copia las imágenes originales al ACR
de la instancia y coordina jobs de migraciones, permisos PostgreSQL y activación de API/Workers.
Terraform sigue siendo la única herramienta que define y modifica infraestructura.

Con el perfil [Keycloak integrado en dev](auth-y-base-compartida.md), después de ApplyMaintenance
se ejecutan `KeycloakDatabase`, `PrepareIdentity` y `ApplyIdentity` (plan revisado en despachos
separados). Se prepara entonces el realm/cliente; solo después se admiten las migraciones y
activación. La guía de identidad detalla secretos, permisos y límites. El perfil de emisor
externo conserva la secuencia original.

La [publicación SPA y verificación de salud](publicacion-spa-y-salud.md) completa ahora las etapas
PublishWeb y VerifyServing. El recorrido autenticado navegador → API → Worker y la limpieza
integral automática siguen pendientes en 9C. applicationVerified permanece false; Completed
acredita una etapa concreta. La ejecución Azure real continúa pendiente.

## Precondiciones

Para el perfil API-only sin mensajería, omitir el root messaging del inventario y usar los inputs
exportados con `messaging_enabled=false`. La entrega valida esa ausencia y la vincula a su hash.
Se necesita un candidato nuevo de operaciones para `messagingEnabled=false`; no se reutiliza una
imagen anterior. El recorrido Acceptance con mensajería de esta guía corresponde al perfil ml;
no acredita por sí mismo aceptación cloud de mx.

1. Una reserva efímera real dev/staging, con identidad, contenedor, Environment protegido y
   diagnóstico de aislamiento satisfactorio. Producción y ambientes persistentes siguen fuera de
   este bloque. No se ejecutan los ejemplos ficticios contra una cuenta real.
2. Hosting base y mensajería creados con Genesis y observados como `Verified`, con imágenes por
   digest, `maintenance_jobs_enabled=false` y `application_rollout_enabled=false` al iniciar.
   La mensajería usa los principal IDs reales de hosting que enlaza Genesis.
3. `descriptor.json`, `release.json` y `definition.json` fijados en
   `.config/environments/<environment>/<instance>/`, con los hashes del inventario y sus commits.
   Los bindings de hosting y referencias Key Vault proceden del snapshot revisado. No se aceptan
   nombres de recursos ni comandos libres como parámetros de entrega.
4. Tres candidatos de CI satisfactorios de main: backend, web y operaciones DevOps. Deben seguir
   disponibles dentro de su retención de 30 días. Los candidatos de PR no son desplegables.
5. Secreto **`HEXAGON_ARTIFACTS_READ_TOKEN`** del Environment, con acceso de lectura `Actions: read`
   a los repositorios privados de backend y frontend. El candidato del propio repositorio DevOps
   usa `github.token` con `actions: read`. El permiso `Contents: read` por sí solo no descarga
   artefactos de Actions; `read:packages` tampoco sirve para esto. No se necesita escritura de
   paquetes ni publicar otra versión de `Hexagon.Core.*`. La evolución a GitHub App sigue vigente.

Los roles de la reserva se conservan: Contributor en sus propios grupos permite importar al ACR
con su modo RBAC actual; la identidad de cada workload recibe AcrPull. No se activa el usuario
administrador del registry ni se usa una clave de cuenta. Un cambio de modo/permisos del ACR
requiere adaptar explícitamente esta composición, sin ampliar automáticamente permisos.

## Selección declarativa de candidatos

Añade `delivery.json` junto a la definición de la instancia, mediante PR a main:

```json
{
  "apiVersion": "hexagon.ec/application-delivery/v1",
  "releaseSha256": "<SHA-256 del archivo release.json>",
  "candidates": {
    "backend": { "runId": 101, "runAttempt": 1, "artifactId": 201, "archiveSha256": "<SHA-256 del ZIP de GitHub>" },
    "web": { "runId": 102, "runAttempt": 1, "artifactId": 202, "archiveSha256": "<SHA-256 del ZIP de GitHub>" },
    "devops": { "runId": 103, "runAttempt": 1, "artifactId": 203, "archiveSha256": "<SHA-256 del ZIP de GitHub>" }
  }
}
```

Los valores entre `<...>` son indicaciones, no una definición válida. El esquema estricto está en
[ApplicationDelivery v1](../contracts/schemas/application-delivery-v1.schema.json). El repositorio,
commit y manifiestos esperados se obtienen del release; no del archivo descargado.

Consulta los IDs y el campo `digest` de GitHub con acceso de lectura al repositorio correspondiente:

```powershell
gh api repos/<owner>/<repo>/actions/runs/<run-id>/artifacts `
  --jq '.artifacts[] | {id,name,digest,expired,workflow_run}'
(Get-FileHash ./.config/environments/dev/<instance>/release.json -Algorithm SHA256).Hash.ToLowerInvariant()
(Get-FileHash ./.config/environments/dev/<instance>/definition.json -Algorithm SHA256).Hash.ToLowerInvariant()
(Get-FileHash ./.config/environments/dev/<instance>/delivery.json -Algorithm SHA256).Hash.ToLowerInvariant()
```

`archiveSha256` es el campo `digest` del candidato sin `sha256:`. Es el checksum del ZIP que
GitHub distribuye, distinto de `artifacts[].sha256` en build.json y del digest del manifiesto OCI.
No se selecciona el candidato más reciente ni se usa `latest`. El URI web del release no se usa
como descarga arbitraria: se consume el candidato web seleccionado y se contrasta su checksum.

## Orden de ejecución

Usa **Application Delivery**, siempre desde main. Selecciona ambiente, instancia, hash de la
definición y hash de `delivery.json`; cada fila corresponde a un despacho independiente:

| Etapa | Resultado exigido |
| --- | --- |
| `Artifacts` | Verifica los tres candidatos y copia imágenes backend/bootstrap al ACR, sin reconstruir |
| `PrepareMaintenance` | Enlaza outputs de mensajería, habilita jobs y guarda un plan privado con hash |
| `ApplyMaintenance` | Aplica exactamente ese plan después de revisarlo; aún no ejecuta jobs |
| `Migrations` | Ejecuta o reconcilia el job `--migrate-only`; solo Succeeded acredita migraciones |
| `DatabaseAccess` | Revalida migraciones y ejecuta el bootstrap de roles, permisos y RLS por identidad |
| `PrepareActivation` | Revalida ambas ejecuciones e imágenes; habilita rollout y prepara otro plan |
| `ApplyActivation` | Revalida las precondiciones y aplica el plan revisado de API y Workers |
| `PublishWeb` | Publica el candidato SPA con overlay público, sin build y con intención durable |
| `VerifyServing` | Compara los archivos servidos y observa salud actual; conserva evidencia por hash |

Para cada Apply proporciona el `reviewSha256` devuelto por su Prepare y la confirmación exacta
`CREATE <product> <environment> <instance>`. Revisa el JSON privado del plan en el contenedor de la
instancia antes del segundo despacho. El hash de un plan de mantenimiento no autoriza activación.
El motor conserva sus comprobaciones de vigencia, revisión, snapshot, destino y estado.

El workflow comparte exclusión mutua por repositorio/ambiente con Genesis y Apocalypse, usa el
mismo Environment protegido y verifica sus variables antes de Azure login/OIDC. Cada ejecución
acredita el aislamiento real antes de entregar imágenes o arrancar jobs. No hay ejecución desde PR.

Los bindings de mensajería se toman del root aplicado y se añaden por workload; los conflictos se
bloquean. Credenciales de servicios externos continúan siendo referencias Key Vault, nunca valores
en JSON. Las conexiones PostgreSQL de mantenimiento usan Entra ID y VerifyFull. Los jobs deben
mantener la identidad, imagen, argumentos y configuración esperados; no aceptan comandos del YAML.

## Evidencia y recuperación

El inventario de infraestructura no cambia de versión. `delivery.json` remoto es un journal
separado dentro de `<product>/<environment>/<instance>/`, protegido por el mismo lease y CAS con
lectura posterior. Está ligado al hash de selección, release, destino e IaC. No es el archivo
de selección versionado, aunque ambos se llaman delivery.json. Conserva imágenes confirmadas,
propósito/hash del plan y estado de cada intento de mantenimiento; no contiene tokens ni salidas
libres de procesos. Los hashes de los inputs de hosting y del estado de mensajería invalidan
evidencia de jobs cuando cambia su contexto.

- **Descarga o copia interrumpida:** repite `Artifacts` antes de comenzar mantenimiento. La copia
  es por contenido y omite blobs existentes, comprobando sus digests. No recompila ni publica NuGet.
- **Terraform interrumpido:** ejecuta Genesis `Sync` para hosting, inspecciona el resultado y prepara
  un plan nuevo de la etapa correspondiente. No reutilices un hash anterior.
- **Job interrumpido:** vuelve a despachar la misma etapa. Se guarda el intento antes de POST y se
  añade `HEXAGON_DELIVERY_ATTEMPT` al template de esa ejecución. La recuperación solo adopta una
  ejecución con ese marcador y template exactos. Nunca vuelve a arrancar a ciegas tras un timeout.
- **Intento sin ejecución visible o ambiguo:** se bloquea conservando evidencia. Investiga el job y
  el journal con un operador. No borres el checkpoint para forzar otro POST. No hay reinicio
  automático de un job fallido; para esta referencia efímera se puede retirar la instancia mediante
  Apocalypse y crear otra reserva tras corregir la causa.
- **Artefacto expirado:** no hay fallback a una build nueva o una rama. Selecciona un candidato
  válido en un release/reserva nuevos; no sustituyas la selección de una instancia ya iniciada.
- **Retirada:** Apocalypse sigue recuperando la infraestructura sin necesitar artefactos, tokens de
  aplicaciones ni este journal. Quiesce y destrucción conservan el procedimiento manual revisado.

El lease siempre se libera al salir normalmente; un proceso muerto puede dejar el lease infinito
retenido. La intervención manual sigue la guía del adaptador. Nunca se rompe automáticamente.

## Límites probados

`tests/Test-ApplicationDelivery.ps1` usa archivos OCI/SPA reales y dobles HTTP para demostrar:
procedencia de main/CI success, checksums y contratos exactos, rechazo de ZIP inseguros, separación
de credenciales en redirecciones, copia de bytes sin cambiar digests, CAS, intents durables y
recuperación sin duplicar POST. Las pruebas del motor cubren planes y snapshots con Git/Terraform
locales. Estas pruebas no sustituyen una ejecución real de Azure, identidades, registry y jobs.

Protocolos de referencia: [artefactos de Actions](https://docs.github.com/en/rest/actions/artifacts),
[OAuth de ACR](https://github.com/Azure/acr/blob/main/docs/AAD-OAuth.md),
[arranque de jobs](https://learn.microsoft.com/en-us/rest/api/resource-manager/containerapps/jobs/start?view=rest-resource-manager-containerapps-2024-03-01)
y [consulta de ejecuciones](https://learn.microsoft.com/en-us/rest/api/resource-manager/containerapps/job-execution/job-execution?view=rest-resource-manager-containerapps-2024-03-01).
