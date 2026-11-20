# Separación por nube

Esta plantilla se divide en una base común y una plantilla por nube
([ADR 0043](https://github.com/ajunquit/hexagon-template-ng/blob/main/docs/adr/0043-una-plantilla-devops-por-nube.md)):

| Repositorio | Contenido |
| --- | --- |
| `hexagon-core-devops` | Lo que no depende de la nube. Es este repositorio, renombrado, con su historia y sus ADR. |
| `hexagon-template-devops-aws` | AWS: ECS Fargate, RDS, S3 y CloudFront, SNS/SQS. |
| `hexagon-template-devops-az` | Azure: Container Apps, Static Web Apps, PostgreSQL, Service Bus. |

Esta guía recoge la **fase 1**: el inventario de cada archivo y el contrato del adaptador de nube.
El plan completo está en la continuidad de Hexagon (`plan-devops-por-nube.md`).

## El inventario

[`scripts/cloud-classification.json`](../scripts/cloud-classification.json) clasifica cada archivo
versionado con reglas ordenadas: **gana la primera que coincide**, y `*` también cruza carpetas.

| Clase | Destino |
| --- | --- |
| `common` | La base |
| `history` | La base. Son los ADR y el CHANGELOG, que no se reescriben |
| `repository` | Cada repositorio tiene el suyo: README, AGENTS y la configuración del editor |
| `aws` | La plantilla de AWS |
| `azure` | La plantilla de Azure |
| `mixed` | Se divide en la fase 2 antes de moverse. Cada regla dice cómo |

```powershell
python ./scripts/cloud_classification.py check    # lo ejecuta Test-Repository
python ./scripts/cloud_classification.py report   # recuento y lista de archivos mixtos
```

**`check` falla si:**
- un archivo no tiene regla, o una regla no coincide con ninguno;
- un archivo `common` nombra servicios de una nube, o uno de una nube nombra la otra. Los nombres
  lógicos de mensajería del contrato del backend (`aws-sns-sqs`, `azure-service-bus`) están
  permitidos;
- un script `common` importa uno de una nube, o una nube importa la otra. Importar uno `mixed` se
  admite hasta que se divide.

**Un archivo nuevo se clasifica en el mismo PR.** Si se duda, se marca `mixed` y se explica cómo se
divide. La prueba solo se ejecuta en la plantilla: las instancias de los productos migran por la
fábrica.

### Punto de partida

Inventario en `a940b5c`:

| Área | common | history | repository | aws | azure | mixed |
| --- | --- | --- | --- | --- | --- | --- |
| raíz | 0 | 1 | 7 | 0 | 0 | 0 |
| `.agents`, `.claude`, `local`, `products` | 0 | 0 | 7 | 0 | 0 | 0 |
| `.config` | 0 | 0 | 1 | 0 | 1 | 0 |
| `.github` | 0 | 0 | 1 | 0 | 0 | 5 |
| `acceptance` | 4 | 0 | 0 | 1 | 0 | 1 |
| `contracts` | 14 | 0 | 0 | 3 | 3 | 8 |
| `docs` | 1 | 26 | 0 | 1 | 5 | 17 |
| `examples` | 4 | 0 | 0 | 4 | 5 | 2 |
| `operations` | 4 | 0 | 0 | 10 | 3 | 30 |
| `scripts` | 15 | 0 | 2 | 9 | 22 | 35 |
| `terraform` | 30 | 0 | 0 | 85 | 85 | 6 |
| `tests` | 8 | 0 | 1 | 4 | 8 | 23 |
| **Total** | **80** | **27** | **19** | **117** | **132** | **127** |

Terraform ya está separado por nube: sus módulos y roots no se mezclan. El acoplamiento está en la
orquestación.

### Hallazgos

- **Había piezas comunes dentro de módulos con nombre de nube.** Se extrajeron en la fase 2a:

  | Pieza | Antes | Ahora |
  | --- | --- | --- |
  | JSON canónico y hash de bytes | `PlatformBootstrap.psm1` y `AzureEnvironmentStore.psm1` | `CanonicalJson.psm1` (`ConvertTo-CanonicalJson`, `Get-LifecycleBytesHash`) |
  | Insumos de la aceptación | `AzureAcceptance.psm1` | `AcceptanceContracts.psm1` |
  | Herramientas de cada nube | Dentro de `LifecycleNative.psm1` | `AzureLifecycleTools.psm1` y `AwsLifecycleTools.psm1` |
  | Host de la SPA y su archivo de control | Dentro de `StaticWebPublication.psm1` y `StaticWebConfiguration.psm1` | `AzureWebHost.psm1` y `AwsWebHost.psm1` |

  Ningún módulo de AWS carga ya uno de Azure, ni al revés. AWS deja de generar el archivo de control de
  Azure (`staticwebapp.config.json`), que nunca subía.
- **Los puntos de entrada ramificaban por nube.** `Invoke-EnvironmentWorkflow.ps1` e
  `Invoke-ApplicationDelivery.ps1` decidían con `if ($aws)` entre dos familias equivalentes. Desde la
  fase 2b usan el adaptador de nube. Los workflows `genesis`, `apocalypse` y
  `delivery` también decidían la nube; desde la fase 2d abren la sesión con la acción de la nube
  (ver abajo). `platform-diagnostic` solo existe en Azure.
- **Ocho contratos compartidos llevaban valores de una nube:** destinos, ARN, registros o variables.
  Desde la fase 2e, seis tienen un esquema neutral y una variante por nube (ver abajo).
  `platform-bootstrap-v1` es de Azure, y `local-messaging-bindings-v1` se divide con la mensajería
  local.
- **El motor fijaba reglas de proveedor:** tipos prohibidos, prefijos y alcance del plan. Desde la
  fase 2c están en `*EnvironmentRules.psm1`, y `EnvironmentLifecycle.psm1` y
  `EnvironmentSnapshot.psm1` son comunes.
- **Las dos herramientas .NET mezclan nubes por proyecto:** `Hexagon.Database.Bootstrap` y
  `Hexagon.Messaging.Operations`. Lo genérico va a la base y los SDK de cada nube a su plantilla.

## El contrato del adaptador de nube

Cada nube aporta un módulo `<Nube>CloudAdapter.psm1` (`AwsCloudAdapter.psm1`, `AzureCloudAdapter.psm1`)
con las mismas funciones. `CloudAdapters.psm1`, de la base:
- descubre esos módulos;
- elige el que reconoce el destino del inventario;
- llama a sus funciones dentro del módulo.

Los puntos de entrada (`Invoke-EnvironmentWorkflow.ps1` e `Invoke-ApplicationDelivery.ps1`) ya no
preguntan qué nube es. Una nube nueva (GCP) solo añade su módulo.

| Función | Responsabilidad | Estado |
| --- | --- | --- |
| `Test-CloudTarget` | Reconoce el destino de su nube en el inventario | Fase 2b |
| `Get-CloudName` | Nombre corto de la nube (`aws`, `azure`), usado en los códigos de error | Fase 2b |
| `Get-CloudTargetDetails` | Datos públicos del destino y del enlace de GitHub | Fase 2b |
| `Get-CloudEnvironmentEntry`, `Get-CloudEnvironmentResultVersion` | Punto de entrada nativo del ambiente y versión de su resultado | Fase 2b |
| `Get-CloudStoreDescription` | Dónde quedan el inventario, los planes y la evidencia | Fase 2b |
| `Test-CloudDeliveryStage` | Etapas de entrega que existen en la nube (`DatabaseCredentials` solo en AWS) | Fase 2b |
| `Enter-CloudLifecycle`, `Exit-CloudLifecycle` | Contexto con la identidad verificada y lease de la instancia | Fase 2b |
| `Get-CloudLifecycleJournal` | Journal duradero de la instancia | Fase 2b |
| `Invoke-CloudApplicationStage` | Etapa de entrega de aplicaciones | Fase 2b |
| Reglas del ambiente | Tipos prohibidos, prefijos o grupos de recursos, alcance del plan, destino del preflight y del journal, y roots que empaqueta el snapshot | Fase 2c, en `<Nube>EnvironmentRules.psm1` |

Las reglas del ambiente van en un módulo aparte, `<Nube>EnvironmentRules.psm1`, porque el motor las
necesita y el adaptador ya depende del motor. Cada nube trae su adaptador y sus reglas.

`tests/Test-CloudAdapters.ps1` comprueba que cada adaptador y cada módulo de reglas cumplen el contrato,
que hay tantas reglas como adaptadores y que un destino que ninguna nube reconoce se rechaza
(`lifecycle.cloud.targetUnsupported`).

**Reglas del contrato:**
- Las mantiene el [ADR 0027](adr/0027-adaptador-de-nube-y-base-comun.md).
- **El adaptador orquesta; no abstrae la infraestructura.** Los módulos Terraform de cada nube
  siguen separados y con su propia semántica (regla 6 de AGENTS).
- La base no elige un adaptador por defecto. Sus pruebas usan un doble, que nunca va a un workflow
  real.
- **Los workflows del ciclo son comunes** (`genesis`, `apocalypse`, `delivery`): no se autentican ni
  ramifican por nube. Abren la sesión con `.github/actions/cloud-session`, que recibe los datos
  públicos del destino y las variables del Environment:

  | Acción | Clase | Qué hace |
  | --- | --- | --- |
  | `.github/actions/aws-session` | `aws` | Comprueba `AWS_ROLE_ARN`, `AWS_REGION` y `AWS_ACCOUNT_ID` y asume el rol por OIDC |
  | `.github/actions/azure-session` | `azure` | Comprueba `AZURE_CLIENT_ID`, `AZURE_TENANT_ID` y `AZURE_SUBSCRIPTION_ID`, inicia sesión por OIDC e instala el cliente de contenido estático para `PublishWeb` |
  | `.github/actions/cloud-session` | `repository` | Llama a la acción de la nube del destino. Cada plantilla trae la suya, que solo llama a su nube |

  `Test-Repository` comprueba que esos workflows solo abren la sesión por `cloud-session` y que toda
  acción externa está fijada por commit.
- La mensajería local, la CI y Floci siguen la misma idea. La base trae RabbitMQ y el mecanismo;
  cada plantilla registra su emulador, sus pruebas y su runner de Floci.
- **Lo que la base descubre por nombre**, sin importar de qué nube es:
  - `*LifecycleTools.psm1`: las herramientas de línea de comandos de la nube y las variables de entorno
    que no deben llegarles;
  - `*WebHost.psm1`: los archivos de control del host de la SPA y sus hosts públicos;
  - `*EnvironmentRules.psm1`: las reglas del ambiente, que descubre `EnvironmentLifecycle.psm1`;
  - `<nube>-<contrato>.variant.json`: la variante de un contrato, que compone `ContractSchemas.psm1`;
  - `*EphemeralEnvironment.psm1`: la reserva efímera de la nube (definición, cuenta, plan, salidas y
    diagnóstico de aislamiento), que descubre `EphemeralEnvironment.psm1`;
  - `*OperationsPolicy.psm1`: la operación de cada proveedor de mensajería y su clase de pruebas de
    CI, que descubre `MessagingOperations.psm1`;
  - `*LocalMessaging.psm1`: el emulador local de cada proveedor, que descubre `LocalMessaging.psm1`;
  - `*Repository.psd1`: las rutas, pruebas y roots Terraform de la nube, que añade
    `Test-Repository.ps1` a las comprobaciones de la base;
  - `tests/fixtures/operations/*.ps1` y `tests/fixtures/local-messaging/*.ps1`: los fixtures de cada
    proveedor de las pruebas comunes.

  En .NET, cada nube aporta sus clases (`IMessagingProvider`, `IDatabaseMaintenance`), que la base
  descubre por reflexión, y sus SDK en `Cloud.<Nube>.props` y `Packages.<Nube>.props`, que los
  proyectos importan por comodín. Cada nube trae también su acción de sesión
  (`.github/actions/<nube>-session`), su runner de Floci (`tests/Invoke-FlociRoots<Nube>.ps1`) y sus
  guías (`docs/*-<nube>.md`).

### Contratos con variantes por nube

`Test-Json` no resuelve referencias a otros archivos sin descargarlas, así que un contrato no puede
importar la parte de cada nube. En su lugar:

- **El esquema neutral** (`contracts/schemas/<contrato>.schema.json`) marca cada parte que depende de
  la nube como una definición cuyo nombre empieza por `cloud` (`cloudTarget`, `cloudRoot`,
  `cloudDetails`, `cloudImage`, `cloudJobId`, `cloudDocument`) y la deja neutral.
- **Cada nube aporta** `<nube>-<contrato>.variant.json` con las mismas definiciones, que restringen la
  neutral: patrones de identificadores, campos del destino y campos obligatorios.
- **`scripts/ContractSchemas.psm1` compone** un esquema en memoria. Cada parte acepta la variante de
  cualquier nube del repositorio: la definición neutral más la restricción de esa nube, sin
  propiedades que ninguna de las dos evalúe. Si no hay ninguna variante, no acepta nada. Los scripts
  validan con `Test-ContractJson`, no con `Test-Json -SchemaFile`.

| Contrato | Partes por nube |
| --- | --- |
| `environment-inventory-v1` | `cloudTarget`, `cloudRoot` (adaptador, prefijo o grupo, identificadores y tipos de recurso) |
| `acceptance-cleanup-consent-v1` | `cloudRoot` |
| `application-delivery-journal-v1` | `cloudImage`, `cloudJobId` |
| `application-delivery-result-v1`, `environment-workflow-result-v1` | `cloudDetails` |
| `ephemeral-environment-v1` | `cloudDocument`: la reserva de cada nube, elegida por el destino del inventario |

`tests/Test-CloudAdapters.ps1` comprueba que cada contrato con partes por nube tiene una variante por
nube del repositorio, solo esas, y que no acepta un documento vacío.

  Esos módulos no exportan nada. La base llama a sus funciones dentro del módulo, así que los de
  distintas nubes no chocan mientras conviven en este repositorio.

## Estado de la fase 2

La fase 2 dividió los archivos `mixed` en el sitio, sin cambiar de repositorio: ya no queda ninguno.
Cada archivo es `common`, `history`, `repository`, `aws` o `azure`. Las pruebas que usan dobles de una
nube viajan con esa nube; la base conserva las pruebas de sus mecanismos con RabbitMQ y con el
contrato de los módulos descubiertos. `ruta-plataforma.md` y `fase-9-entrega-producto.md` registran
fases pasadas y se tratan como historia.

## Fase 3: repositorios

Este repositorio es `hexagon-core-devops`: contiene solo los archivos `common`, `history` y los suyos.
Las plantillas `hexagon-template-devops-aws` y `hexagon-template-devops-az` contienen:

- la copia de la base en un commit exacto, con el SHA-256 de cada archivo en
  `.config/hexagon-core-devops-source.json`. `python scripts/cloud_classification.py base` lista esos
  archivos (lo común y la historia, sin el CHANGELOG) y `scripts/Update-CoreDevops.ps1` los copia;
- los archivos de su nube;
- sus archivos propios (`repository`), como `.github/actions/cloud-session`, que solo llama a su nube.

`Test-Repository.ps1` de una plantilla rechaza cualquier archivo de la base modificado en el sitio.
La clasificación de cada repositorio conserva solo las reglas que usan sus archivos, y sus
comprobaciones siguen vigentes: lo común no nombra nubes y una nube no nombra la otra.
