# Primera referencia de hosting: Azure administrado

La fase 9A implementa la composición de referencia elegida por el dueño: **Azure Container Apps y
Azure Static Web Apps**, con Terraform. Los contratos siguen siendo lógicos y las imágenes OCI
portables. El broker se elige por separado; esta composición no convierte Azure Service Bus en una
dependencia del dominio ni crea infraestructura desde las aplicaciones.

## Recursos y límites

El mismo hosting admite una API sin mensajería para mx. La capacidad se deriva del descriptor
explícito sin requisitos de mensajería y se valida como API-only. Su inventario no incluye el
root messaging y el bootstrap no concede rol outbox. Ver [ADR 0022](adr/0022-un-devops-para-monolitos-simples-y-modulares.md).

`terraform/modules/hosting/azure` y los roots `environments/{dev,staging,prod}/hosting-azure` crean:

- VNet y subredes delegadas para cómputo y PostgreSQL, con DNS privado, en el grupo del bootstrap;
- PostgreSQL Flexible Server 17 privado, TLS y autenticación Entra; el perfil Keycloak habilita además contraseña;
- Container Registry sin cuenta administrativa y permisos AcrPull por identidad;
- Container Apps Environment con Log Analytics, una identidad por API/Worker y otra de mantenimiento;
- Static Web Apps Standard con su dominio HTTPS administrado por ambiente;
- dos jobs manuales: migraciones y bootstrap de acceso a datos, activados después de publicar imágenes;
- API con ingress HTTPS a 8080 y sondas internas en 8081; Workers sin ingress público y mínimo una réplica.

Esta referencia usa los dominios administrados de Azure; no crea una zona DNS organizacional ni un
WAF compartido. Un dominio propio exige su configuración explícita y un origen CORS/callback
coherente antes de adoptarlo. Se puede referenciar un emisor externo o adoptar el perfil opcional
[Keycloak integrado en dev](auth-y-base-compartida.md), con una sola base de aplicación y esquema
dedicado. Este perfil añade un proceso y un job SQL, sin implementar el módulo Auth. Requiere
Terraform >= 1.11 y tres referencias versionadas a secretos preparados por el operador. Tampoco se crea un clúster
RabbitMQ ni infraestructura de AWS desde este módulo. Sus hosts y credenciales deben resolverse
antes de seleccionarlos para una combinación distinta de la referencia Azure.

## Contratos, política y artefactos

`ProductEnvironment` v1 conserva commits y SHA-256 de manifiestos. Para incluir hosting backend:

```powershell
pwsh ./scripts/New-ProductEnvironmentDescriptor.ps1 `
  -Product hexagon-example -Environment dev `
  -BackendRepository ajunquit/hexagon-example-dotnet-ml -BackendRef <commit-backend> `
  -FrontendRepository ajunquit/hexagon-example-ng -FrontendRef <commit-web> `
  -IncludeBackendHosting
```

Fija `BackendHostingRequirements` v1 junto al contrato de mensajería y
`FrontendHostingRequirements` v2. El esquema frontend v1 se conserva para consumidores anteriores;
la referencia nueva exige v2 porque utiliza identidad pública.

`AzureHostingPolicy` v1 define nombres, red, capacidad, cliente Auth existente y bindings por
workload. Véase `examples/azure-hosting-policy.json`; no contiene secretos. Las credenciales van en
`secret_references`, con URI Key Vault y resource ID del vault correspondiente. El módulo asigna
`Key Vault Secrets User` por workload/vault; se recomienda un vault dedicado al producto/ambiente.
`environment` contiene solo valores públicos o técnicos no secretos. No se pueden reemplazar los
ajustes de identidad, conexión, puertos o CORS que controla el hosting. Las URI de secretos deben
corresponder al vault declarado. La resolución efectiva, RBAC y red se verifican en 9C.

`ApplicationRelease` v1 completa la trazabilidad de artefactos. `examples/application-release.json`
es ficticio y no desplegable. Registra:

| Campo | Evidencia |
| --- | --- |
| `sources` | Repositorio, commit completo y manifiestos con checksum, exactamente iguales al descriptor |
| `artifacts.backend` | Una imagen por workload, con `@sha256:<digest>`; no se admiten tags mutables |
| `artifacts.web` | URI HTTPS del bundle y SHA-256 de sus bytes |
| `artifacts.databaseBootstrap` | Repositorio/commit DevOps e imagen del bootstrap fijada por digest |

El registro es independiente del ambiente: la promoción mantiene fuentes y artefactos. El
descriptor del destino debe declarar los mismos contratos; solo varían las políticas y bindings.
La exportación reemplaza el origen del registro por el ACR del ambiente, conservando repositorio y
digest. La promoción debe copiar exactamente esas imágenes al destino antes de activar jobs o apps;
el registro de release conserva la referencia original y no se modifica al cambiar de ambiente.
El validador comprueba forma y correspondencia de fuentes; no acredita por sí solo procedencia de
una imagen ni descarga el bundle. En 9B, el productor generará estos valores; en 9C/9D, el consumidor
verificará los bytes/digests descargados antes de ejecutar o publicar. Un checksum de un archivo
tar de imagen no sustituye el digest OCI del registro.

```powershell
pwsh ./scripts/Test-ApplicationRelease.ps1 -Descriptor <descriptor.json> `
  -Release <release.json> -VerifySources
pwsh ./scripts/Export-AzureHostingInputs.ps1 -Descriptor <descriptor.json> `
  -Release <release.json> -Policy <azure-hosting-policy.json> `
  -Output ./terraform/environments/dev/hosting-azure/generated.auto.tfvars.json
```

La exportación verifica manifiestos y esquemas remotos desde sus commits, rechaza workloads sin
imagen/política o sobrantes y toma puertos, migración, audiencia y scope del contrato backend.
Genera ambos indicadores de activación en `false`. Los archivos generados no se confirman en Git.

## Orden de activación

El estado remoto Azure se prepara con el bootstrap existente, fuera del root de hosting. Usa una
key exclusiva como `hexagon-example/dev/hosting-azure.tfstate`; nunca compartas key con mensajería
ni con otro ambiente. Configura la suscripción/tenant mediante identidad de despliegue y variables
de entorno del proveedor. No se incluyen credenciales en tfvars ni se aplica desde una estación
local a ambientes compartidos.

La automatización de 9B/9C seguirá este orden, con revisión y evidencia:

1. Crear infraestructura con `maintenance_jobs_enabled=false` y
   `application_rollout_enabled=false`. No se intenta descargar de un ACR recién creado y vacío.
2. Publicar las imágenes verificadas al ACR y resolver sus digests. Las imágenes de workloads y
   bootstrap deben pertenecer al registro del ambiente; sus bytes/digests se conservan al promover.
3. Usar `workload_identities` en las políticas de mensajería existentes. Aplicar permisos mínimos
   y entregar sus `workload_bindings` a cada entrada de la política de hosting. Para Azure, cada
   proceso usa su UAMI y Data Sender/Receiver, sin Manage. Un secreto de otro adaptador se referencia
   desde Key Vault; esta fase no implementa federación entre clouds.
4. Preparar el cliente público en Hexagon Auth: Code + PKCE S256, sin Direct Access Grants, audience
   y scope del backend. Registrar el origen web exacto y callbacks `/authentication/callback` y
   `/authentication/login` para acceso y logout. No usar comodines ni secretos de cliente en la SPA.
5. Activar `maintenance_jobs_enabled=true`. Ejecutar el job `migrations` y esperar éxito; después
   ejecutar `database-access` y esperar éxito. Terraform define los jobs, **no los ejecuta**.
6. Activar `application_rollout_enabled=true` solo tras esos resultados. Terraform no prueba que
   un job haya terminado: el orquestador debe bloquear este paso si falla o falta evidencia.
7. Verificar salud, obtener `api_url` y generar la configuración pública. Publicar la SPA verificada
   y realizar el recorrido autenticado con tenant. Su implementación cloud corresponde a 9C.

La API no migra al arrancar fuera de Development. El job usa la misma imagen con `--migrate-only`,
sin HTTP ni transporte de mensajería. El bootstrap operativo .NET se construye como imagen SDK:

```powershell
dotnet publish ./operations/Hexagon.Database.Bootstrap -c Release --os linux --arch x64 `
  -t:PublishContainer -p:ContainerRepository=hexagon-database-bootstrap `
  -p:ContainerImageTag=<commit-devops> -p:ContainerArchiveOutputPath=<archivo.tar.gz>
```

La identidad de mantenimiento es administradora Entra de la base. El bootstrap vincula cada rol
PostgreSQL a su object ID exacto y rechaza una identidad distinta o administradora ya asociada.
Entrega NOINHERIT/NOBYPASSRLS y pertenencia sin ADMIN a `hexagon_app`/`hexagon_outbox`; los
interceptores activan estos roles explícitamente. Solo la API recibe lectura del directorio
`platform.Tenants`/`Memberships`. Las aplicaciones no pueden crear roles ni migrar esquemas.
El script no elimina identidades retiradas: una baja requiere revisión y revocación explícita.

## Configuración estática

Con outputs completos del hosting, guardados en una ubicación protegida y temporal:

```powershell
terraform -chdir=terraform/environments/dev/hosting-azure output -json > ./bindings/hosting-outputs.json
pwsh ./scripts/Export-StaticWebConfiguration.ps1 -Descriptor <descriptor.json> `
  -TerraformOutputs ./bindings/hosting-outputs.json -OutputDirectory ./bindings/web-overlay
```

Solo se seleccionan `api_url` y `frontend_authentication`. El resultado contiene
`runtime-config.json` con `apiUrl` HTTPS `/api/v1` y `authentication` público, además de
`staticwebapp.config.json`: fallback a `/index.html`, exclusión de configuración/assets ausentes,
`no-store` en configuración/index y `no-cache` como regla general. Un fichero de configuración
ausente no queda oculto por una respuesta HTML 200 del fallback.

Primero se verifica el checksum del bundle original; después se extrae y se añade este overlay en
la copia de despliegue. El overlay cambia por ambiente y no modifica el artefacto de release ni
su checksum. No se recompila Angular. La API permite por CORS exactamente el origen Static Web Apps
del ambiente. El frontend añade el tenant al recurso y el backend comprueba membresía y permisos.

## Evidencia y pendientes

En 9A se ejecutan pruebas Terraform con proveedor simulado, validaciones de roots, pruebas de
contratos y del overlay, pruebas PostgreSQL 17 de permisos/RLS y migraciones efímeras del backend.
Esto no demuestra disponibilidad, cuotas, RBAC efectivo de Azure ni un login real. No se ejecutó
`terraform apply`, no se publicaron paquetes del core y no se añadieron pipelines.

9B automatiza las verificaciones y construcción. 9C acredita el ambiente efímero, identidad,
publicación y recorrido navegador–API/tenant/mensajería; 9D añade promoción. Antes de uso productivo
se deben revisar disponibilidad, recuperación, límites de costos y controles operativos del
producto. El estado remoto debe protegerse: el proveedor puede almacenar credenciales generadas
por Azure, como el token de publicación del sitio estático, aunque ningún output público las exponga.

Referencias: [Static Web Apps](https://learn.microsoft.com/en-us/azure/static-web-apps/configuration),
[usuarios Entra PostgreSQL](https://learn.microsoft.com/en-us/azure/postgresql/security/security-manage-entra-users),
[roles PostgreSQL Azure](https://learn.microsoft.com/en-us/azure/postgresql/security/security-access-control),
[imágenes con SDK .NET](https://learn.microsoft.com/en-us/dotnet/core/containers/sdk-publish).

## Ajuste pendiente: Auth integrado

La [guía de Auth y base compartida](auth-y-base-compartida.md), conforme a la ADR de plataforma
0036, define la evolución a una única base con esquema `keycloak` y esquemas Hexagon. El hosting
actual no implementa esa composición. Antes del siguiente despliegue se debe resolver su dueño
único, preparación SQL, permisos mínimos y dependencia de retirada, sin un segundo PostgreSQL
para identidad. La referencia real se limita a `dev`.
