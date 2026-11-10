# Fase 9B: CI y construcción de artefactos

La implementación sigue el [ADR 0011](adr/0011-ci-por-componente-y-artefactos-verificables.md).
Cada repositorio tiene `.github/workflows/ci.yml`, independiente de los otros componentes. Se
ejecuta en PR a `main`, push a `main` y manualmente. No tiene credenciales de Azure, permisos de
escritura del repositorio ni despliegues. Terraform sigue siendo la única herramienta IaC.
Los repositorios .NET fijan el SDK en global.json sin roll-forward; setup-dotnet lee ese mismo archivo.

## Qué comprueba cada pipeline

| Componente | Comprobaciones y artefactos |
| --- | --- |
| Frontend | npm ci, formato y seis guardrails, pruebas en ChromeHeadless, build de producción y bundle estático con checksum |
| Backend | Core local fijado por commit, contratos, build sin advertencias, pruebas reales con PostgreSQL/broker efímeros, formato y modelo de cada contexto de módulo; tres archivos OCI |
| DevOps | Contratos y fuentes, pruebas de exportación/integridad, 18 roots Terraform con fmt/validate y pruebas mock, operación real de los tres brokers y ciclo local de topología, permisos/RLS PostgreSQL; archivo OCI del bootstrap |

Las pruebas de integración usan contenedores locales desechables y datos ficticios. Las pruebas
Azure aceptan las licencias del emulador y SQL Server exclusivamente para ese entorno de prueba.
El job de validación comparte la caché de plugins entre roots, sin usar estado remoto.
Los lockfiles incluyen checksums oficiales para Windows/Linux amd64. Al cambiar un proveedor,
regenera sus locks con `terraform providers lock -platform=windows_amd64 -platform=linux_amd64`
antes de comprobar init con `-lockfile=readonly`; no se relaja la verificación de paquetes.

La copia de política Azure para la prueba del ciclo local fija TTL PT1H y ventana de duplicados
PT5M, límites del emulador 2.0. El generador rechaza valores superiores antes de escribir archivos;
no modifica la política cloud. La prueba falla también si no puede retirar sus contenedores.

`Test-Repository.ps1 -VerifySources` verifica los descriptores reales de `products/` desde sus
commits y SHA-256. Una plantilla sin descriptores no hace lecturas remotas de aplicaciones. Los
ejemplos siguen siendo ficticios y no se presentan como fuentes desplegables verificadas.
Si existen descriptores con repositorios privados, configura `HEXAGON_APPLICATIONS_READ_TOKEN`
con lectura del contenido de esas aplicaciones. El GITHUB_TOKEN de un repositorio no proporciona
acceso automático al contenido privado de otro.

## Core local en el runner

El backend fija repositorio y SHA completo en `.config/hexagon-core-source.json`. El checkout del
core es hermano del backend para no heredar su nuget.config. `prepare-ci-core.ps1` exige ese commit
y un árbol limpio, ejecuta el empaquetador existente y genera `core-build.json` con versión exacta
y checksum de cada paquete. El feed y los NuGet permanecen únicamente en el almacenamiento temporal
del runner; no se suben a Actions ni a un registro de paquetes.

`scripts/nuget.ci.config` mapea Hexagon.Core exclusivamente a ese feed y los paquetes de terceros a
nuget.org. Restore, build y publish reciben la misma versión exacta por propiedad MSBuild. El
build.json final conserva la evidencia de dependencia. Cambiar de core exige revisar otro commit
en el pin; no se usa una rama mutable ni el paquete local más reciente de otra ejecución.

Configura `HEXAGON_CORE_READ_TOKEN` en el repositorio backend: un token fine-grained con
**Contents: read** limitado a `hexagon-core-dotnet`. No necesita Packages:write ni acceso a Azure.
`GITHUB_PACKAGES_TOKEN` con solo read:packages permite descargar paquetes publicados, pero no clonar
el código privado. Un token local tampoco se convierte automáticamente en un secreto de Actions.
Si falta el acceso, el job backend falla con una explicación antes de compilar; no omite pruebas
para aparentar éxito. Los PR externos sin esa lectura necesitan revisión y ejecución desde una
rama autorizada; nunca se usa pull_request_target para sortear esa separación.

## Acceso privado: solución actual y evolución a GitHub App

Para desbloquear 9B se conserva un PAT fine-grained separado, guardado como
`HEXAGON_CORE_READ_TOKEN` en Actions del backend y limitado a **Contents: read** de
`hexagon-core-dotnet`, con caducidad y renovación previstas. `GITHUB_PACKAGES_TOKEN` conserva su
función de descarga de paquetes; no se amplía para leer código. La creación inicial del PAT se hace
manualmente en GitHub; su registro como secreto puede realizarse desde la web o con `gh secret set`.

Para una automatización permanente con varios productos, la evolución recomendada y pendiente es
una **GitHub App**. Cada job que necesite código privado generará un token de instalación temporal,
limitado a los repositorios y permisos necesarios. Se evita distribuir un PAT personal duradero
entre los productos. Los tokens de instalación caducan después de una hora; el workflow deberá
revocarlos al terminar y renovarlos si su duración lo requiere.
[Referencia oficial de autenticación por instalación](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation).

Antes de sustituir el PAT se debe implementar y verificar:

- Registro e instalación de la App con **Contents: read** y acceso solo a los repositorios fuente
  necesarios; identificación de quién administra la App y autoriza nuevos productos.
- Custodia y rotación de su clave privada como secreto, con acceso limitado a los workflows
  autorizados. La App sigue necesitando proteger esa credencial de arranque.
- Emisión por job, restricción explícita de repositorios/permisos y revocación del token temporal,
  sin persistirlo en Git, logs, cachés ni artefactos y sin entregarlo a PR no confiables.
- Checkout del core fijado por commit y CI completo de un producto con la App, antes de retirar
  su `HEXAGON_CORE_READ_TOKEN`; después, adopción y retirada de PAT por producto.

Esta evolución queda registrada para la automatización permanente del acceso a fuentes privadas;
no está implementada ni es un prerrequisito adicional para cerrar 9B. No cambia el empaquetado local
del core ni autoriza publicar paquetes. La identidad federada de despliegue cloud es otro acceso y
se mantiene en las fases de despliegue/promoción.

## ComponentBuild v1

El contrato está en `contracts/schemas/component-build-v1.schema.json`. Cada directorio de entrega
contiene `build.json` y los archivos declarados:

| Dato | Significado |
| --- | --- |
| product, component | Identidad lógica del producto y backend/web/devops |
| repository, commit | Repositorio y SHA completo del checkout construido |
| manifests | Rutas y SHA-256 de los contratos fuente |
| dependencies | Commit/versión del core local y checksums de sus paquetes, cuando aplica |
| artifacts[].sha256 | Checksum de los bytes exactos del archivo distribuido |
| imageDigest, platform | Digest del manifiesto OCI y plataforma de la imagen; no son el checksum del tar |

La SPA entrega `web.tar.gz` sin runtime-config.json ni staticwebapp.config.json. DevOps añadirá el
overlay del ambiente a una copia de despliegue después de verificar el bundle original; no cambia
la build ni su checksum. Se rechazan mapas de fuentes, archivos de credenciales, enlaces y rutas
que puedan escapar del directorio.

Las imágenes se entregan como `.oci.tar`, con blobs comprimidos originales y manifiesto OCI.
Se valida cada blob y descriptor, plataforma Linux y usuario app sin privilegios. 9C deberá
importarlas preservando digests, sin convertir a docker-archive ni reconstruirlas. El checksum
del archivo y el digest de la imagen se conservan por separado.

El bootstrap usa `.config/product.json` para la identidad del producto. Adapta ese archivo al crear
una instancia DevOps; no se deduce el producto de nombres de recursos físicos.

## Verificar una descarga

Después de obtener un artefacto de una ejecución conocida:

```powershell
pwsh ./scripts/Test-ComponentBuild.ps1 -Directory <directorio-del-artefacto> `
  -ExpectedRepository <owner/repo> -ExpectedCommit <commit-completo> `
  -ExpectedProduct hexagon-example -ExpectedComponent backend `
  -SourceDirectory <checkout-fijado-del-backend>
```

Los valores esperados proceden del descriptor y de los metadatos confiables de GitHub, no del
propio JSON descargado. La verificación comprueba checksums, fuente, contratos, workloads y core;
las imágenes se leen sin extraer archivos. Para web y devops cambia ExpectedComponent. Los scripts
de build producen la evidencia, pero no se consideran una firma de procedencia.

Los candidatos solo se conservan desde main, con commit/run ID/reintento en el nombre del artefacto
y 30 días de retención. GitHub también identifica el contenedor ZIP subido con su propio digest;
ese valor no sustituye el checksum del bundle ni el digest OCI. La evidencia de pruebas tiene
7 días de retención. No hay descargas automáticas de un artefacto llamado latest.

En DevOps, el job que construye el candidato depende de las tres integraciones de mensajería y de
la de PostgreSQL: no publica un candidato si alguna de ellas falla.

## Adopción y siguientes etapas

1. Integrar los cambios de frontend/backend y esta instancia DevOps.
2. Adaptar `.config/product.json`, mantener los contratos del producto y fijar el core acordado.
3. Configurar los accesos de lectura privados necesarios y ejecutar CI. Añadir los checks como
   requisitos de protección de main según la política del producto; este cambio no modifica
   automáticamente las reglas de los repositorios.
4. Revisar la ejecución antes de consumir un candidato. Hasta fusionar 9B, sus PR permiten revisar
   la definición; no equivalen a una ejecución satisfactoria de main.

9C preparará las identidades de despliegue, planes cloud revisados, ambiente efímero, publicación
real y recorrido navegador–Auth–API/tenant/mensajería. 9D implementará la promoción duradera y
ApplicationRelease desde los artefactos verificados. En 9B no se ejecuta Terraform apply, no se
emite un plan con estado/secretos cloud ni se publican nuevas versiones de Hexagon.Core.

Referencias: [seguridad de Actions](https://docs.github.com/en/actions/reference/security/secure-use),
[artefactos de Actions](https://github.com/actions/upload-artifact),
[exportación OCI con .NET](https://learn.microsoft.com/en-us/dotnet/core/containers/publish-configuration).
