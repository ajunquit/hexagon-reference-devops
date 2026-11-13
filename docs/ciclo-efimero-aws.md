# Ciclo efímero AWS con Genesis y Apocalypse

Genesis y Apocalypse son el estándar de toda nube ([ADR 0025](adr/0025-ciclo-de-ambiente-en-aws.md)).
Esta guía es el equivalente AWS del [ciclo efímero Azure](ciclo-efimero-azure.md) y crece con cada
incremento de la ADR. Nada de lo descrito aquí se ha ejecutado contra una cuenta real.

## Estado de los incrementos

| Incremento | Estado |
| --- | --- |
| 1. Inventario y motor con target y roots AWS | Integrado ([motor](motor-ciclo-ambiente.md)) |
| 2a. Bootstrap de cuenta y reserva por instancia | Integrado |
| 2b. Definición `EphemeralEnvironment` AWS, orquestación del bootstrap y diagnóstico de aislamiento | Integrado |
| 3a. Custodia en S3: inventario, journal, snapshots y lease | Integrado |
| 3b-1. Catálogo de tipos y sondas, lectura del estado Terraform y restos por etiqueta | Integrado |
| 3b-2. Ejecución de Terraform, puerto del motor y prueba opcional contra AWS Emulator | Integrado |
| 4. `genesis.yml` y `apocalypse.yml` con el proveedor de la definición, y `Quiesce` | Integrado |
| 5a. Entrega AWS: imágenes a ECR, plan de mantenimiento y tareas de base de datos | Integrado |
| 5b. Entrega AWS: identidad, activación, SPA en S3 con CloudFront, verificación y `delivery.yml` | Este documento |
| 6. Aceptación autenticada con limpieza consentida | Este documento |

Con esto el ciclo queda implementado y probado en local. **Nada se ha desplegado:** validar en una
cuenta real requiere la orden expresa del dueño (D-9C-AWS).

## Bootstrap de cuenta y reserva

Como en Azure, la identidad de un ambiente **nunca** prepara su propia base. El operador de la cuenta
aplica, con su autenticación y estados propios en el bucket del bootstrap (`terraform/bootstrap/aws`):

1. **Una vez por cuenta:** [`aws-access`](../terraform/bootstrap/aws-access/README.md). Crea el
   proveedor OIDC de GitHub y el permissions boundary `hexagon-workload-boundary`.
2. **Una vez por reserva:** [`aws-ephemeral`](../terraform/bootstrap/aws-ephemeral/README.md). Crea el
   rol de despliegue de `<producto>-<ambiente>-<instancia>`, federado con el Environment
   `<ambiente>-<instancia>` y limitado a:
   - las etiquetas `hexagon:*` de la instancia;
   - su prefijo corto;
   - su ruta del bucket de estado.

El ID `run-ID-attempt` identifica la reserva y se conserva en todos sus despachos de creación,
reparación y baja. Solo `dev` y `staging` admiten reservas efímeras.

## Definición y preparación de una reserva

`EphemeralEnvironment` v1 admite un inventario AWS ([ejemplo](../examples/ephemeral-environment-aws.json),
ficticio). Además del inventario inicial, la expiración y los revisores, declara:

| Campo | Uso |
| --- | --- |
| `namePrefixBase` | Base del prefijo corto, de 3 a 12 caracteres; la reserva añade `-<6 hex>` |
| `githubOidcProviderArn`, `workloadBoundaryArn` | Salidas de `aws-access` |
| `stateKmsKeyArn` | Clave KMS del bucket de estado del bootstrap |
| `protectedNamePrefixes` | Prefijos vecinos (por ejemplo, los persistentes de dev, staging y prod) sobre los que el diagnóstico debe probar denegación |

El inventario fija la cuenta, la región, el bucket de estado y el rol
`arn:aws:iam::<cuenta>:role/<producto>-<ambiente>-<instancia>-deploy`. Los roots usan el prefijo
`<base>-<6 hex>`, y ningún prefijo protegido puede coincidir con él.

El operador de la cuenta, con sus credenciales de AWS y una GitHub CLI autorizada a administrar
Environments, sigue los mismos cuatro pasos que en Azure, desde `main` actualizado:

```powershell
pwsh ./scripts/Invoke-EphemeralBootstrap.ps1 -Mode Prepare `
  -Definition ./artifacts/reservation-definition.json -Workspace ./artifacts/reservation-review
# Revisar reservation.tfplan y reservation.json: solo el rol y sus políticas, todo create.
pwsh ./scripts/Invoke-EphemeralBootstrap.ps1 -Mode Apply -Definition <...> -Workspace <...> -ReviewSha256 <hash>
pwsh ./scripts/Invoke-EphemeralBootstrap.ps1 -Mode GitHub -Definition <...> -Workspace <...> -ReviewSha256 <hash>
pwsh ./scripts/Invoke-EphemeralBootstrap.ps1 -Mode Verify -Definition <...> -Workspace <...> -ReviewSha256 <hash>
```

Pasos:

1. **Comprobaciones previas.** El script comprueba:
   - que el operador está en la cuenta del inventario y no es el rol de la reserva;
   - que el bucket de estado usa la clave KMS declarada, tiene versionado y bloquea el acceso público;
   - que no hay `AWS_ENDPOINT_URL*` en el entorno.
2. **Estado de la reserva.** Va en `bootstrap/ephemeral/<producto>/<ambiente>/<instancia>.tfstate`,
   con `use_lockfile`.
3. **`Apply`.** Contrasta el rol real con `iam get-role`.
4. **`GitHub`.** Configura el Environment `<ambiente>-<instancia>` solo desde `main`, sin bypass de
   administradores, con `AWS_ROLE_ARN`, `AWS_REGION` y `AWS_ACCOUNT_ID`.
5. **`Verify`.** Devuelve `PreparedForDiagnostic`.

## Diagnóstico de aislamiento

Lo ejecuta el workflow con la **identidad federada real** de la reserva, igual que en Azure:

```powershell
pwsh ./scripts/Test-EphemeralFederation.ps1 -Definition <definition.json>
```

- **Identidad.** Comprueba que quien llama es el rol asumido de la reserva.
- **Casos.** Evalúa con `iam:SimulatePrincipalPolicy` (no crea, cambia ni borra nada) 23 casos más
  tres por cada prefijo protegido:
  - **permitidos:** su estado, crear con sus etiquetas, gestionar lo suyo y crear roles con el
    boundary;
  - **denegados:** el estado persistente de cada ambiente y el del bootstrap; crear con la etiqueta
    de otra instancia; gestionar recursos ajenos; re-etiquetar un rol propio como ajeno; crear un rol
    sin boundary; usuarios IAM; modificar el propio rol de despliegue; y roles, colas y secretos de
    cada prefijo protegido.
- **Resultado.** Solo devuelve `Verified` si todos los casos dan el resultado esperado. Una decisión
  desconocida o un caso que falta nunca acreditan aislamiento.

## Custodia en S3

`AwsEnvironmentStore.psm1` guarda el ciclo de cada instancia en el bucket de estado del bootstrap,
bajo la misma ruta que el rol de la reserva puede escribir:

```text
<producto>/<ambiente>/<instancia>/
  control.json               lease
  inventory.json             journal del inventario
  snapshots/<sha256>.zip     snapshots inmutables
  hosting.tfstate, messaging.tfstate (backend S3 con use_lockfile)
```

Ofrece las mismas garantías que la custodia en Blob de Azure, con escrituras condicionales de S3:

- **Lease:**
  - un único titular. `control.json` se crea con `If-None-Match: *`, o se toma con `If-Match` solo
    si el lease anterior caducó;
  - cada comprobación lo renueva con `If-Match`, y un titular desplazado pierde el lease;
  - S3 no tiene leases infinitos: **caduca a la hora** si no se renueva. Un proceso caído bloquea la
    instancia como mucho ese tiempo.
- **Journal:** se escribe con `If-None-Match` la primera vez y con `If-Match` sobre su ETag después.
  Exige la revisión siguiente, el mismo target y el snapshot ya publicado; una escritura concurrente
  se rechaza.
- **Snapshots:** inmutables. Se escriben una vez y siempre se releen para comprobar su SHA-256.
- **Identidad:** solo el rol asumido de la reserva, en su cuenta, puede abrir la custodia.

Necesita una AWS CLI v2 con `put-object --if-none-match` e `--if-match`. Un fallo de precondición
siempre se trata como conflicto; los mensajes de error de la CLI se usan solo para clasificarlo y no
se registran.

## Presencia y ausencia de recursos

`AwsLifecycleResources.psm1` decide cómo probar cada recurso de los módulos AWS:

- **Cloud Control** (`GetResource`): la mayoría de los tipos, con su identificador derivado del ID de
  Terraform (por ejemplo, `PolicyName|RoleName` o el nombre de un clúster a partir de su ARN).
- **Sondas propias**, para tipos que siguen existiendo tras borrarse o cuyo ID de Terraform no es el
  de Cloud Control:

  | Tipo | Cómo se comprueba | Cuenta como ausente |
  | --- | --- | --- |
  | Clave KMS | Su estado | `PendingDeletion` |
  | Task definition | Su revisión | `INACTIVE` |
  | Servicio ECS | Su estado | `INACTIVE` |
  | RDS | Por `DbiResourceId` | No aparece |
  | Política de autoescalado | Por nombre | No aparece |

- **Recurso padre:** configuraciones sin recurso propio (cifrado, bloqueo público y política de un
  bucket; políticas de una cola; adjuntos de política de un rol).
- **Tipos desconocidos:** bloquean. Una prueba falla si un módulo AWS usa un tipo que no está en el
  catálogo.
- **Respuestas que no acreditan ausencia:** un `AccessDenied`, un throttling o una respuesta
  inesperada son `Unknown`.

La baja completa además consulta la **Tagging API** por la etiqueta `hexagon:instance`. Excluye el rol
de despliegue de la reserva y sus cinco políticas, que pertenecen al bootstrap y llevan la misma
etiqueta. Para que dos instancias no compartan familias de task definition ni políticas de
autoescalado, los nombres de los workloads deben empezar por el prefijo corto; el adaptador lo
exigirá en el 3b-2.

## Adaptador Terraform AWS

`TerraformAwsLifecycle.psm1` es el puerto del motor para AWS, equivalente a `TerraformAzureLifecycle`:

- **Preflight:** comprueba el lease, el workspace del snapshot (archivos, enlaces y versión exacta de
  Terraform), los inputs del root y que quien llama es el rol de la reserva. Valida el plan revisado
  cuando lo hay.
- **Backend S3:** usa la key del root, `use_lockfile` y **SSE-KMS con la clave del estado**, que la
  política del bucket exige. Por eso el target AWS del inventario declara `stateKmsKeyArn`, y la
  custodia también escribe con esa clave.
- **Inputs dentro del ámbito.** Antes de cualquier plan se exige:
  - cuenta, región, ambiente e instancia de la reserva;
  - en hosting, `name_prefix` y el boundary de los workloads (obligatorio en una reserva);
  - en mensajería, el prefijo corto al principio de cada nombre físico: workloads, topics, colas, DLQ,
    roles publicadores y consumidores, y alias KMS.
- **Apply:** solo desde los workflows de confianza de `main`, con el binario revisado. El lease se
  renueva mientras Terraform corre.
- **Observe:** sondas de presencia de cada recurso y convergencia (`plan -detailed-exitcode`). En
  la baja, cuando ya es el último root, los restos por la etiqueta de la instancia. La baja se
  observa hasta cinco minutos, porque Cloud Control y la Tagging API tardan en olvidar lo borrado.
- **Seguridad antes de destruir:** en una instancia `DeleteEphemeral` no puede quedar ningún
  servicio ECS con réplicas ni tareas en ejecución. Queda una evidencia inmutable en la custodia.
  `Quiesce`, que deja los servicios a cero, llega en el incremento 6.

## Prueba opcional con AWS Emulator

`tests/Invoke-AwsEmulatorRoots.ps1` aplica y destruye el root `hosting-aws` contra
[AWS Emulator](https://docs.aws.amazon.com/emulator/latest/userguide/what-is-service.html) en Docker
(decisión del dueño, 2026-11-12). No forma parte de la CI ni de `Test-Repository.ps1`:

```powershell
pwsh ./tests/Invoke-AwsEmulatorRoots.ps1 -EmulatorVersion <versión LTS publicada hace dos semanas o más>
```

El script hace lo siguiente:

- **Imagen:** la construye en local con el paquete exacto de esa versión (lista en
  `https://downloads.aws.com/aws-emulator/packages/aws-emulator/LTS/versions.json`).
- **Arranque:** solo en `127.0.0.1` y con `--telemetry off`.
- **Aislamiento:** quita del proceso las credenciales reales y trabaja en una copia de los roots con
  backend local.
- **Recorrido:** aplica el estado inicial, después el mantenimiento y el rollout, comprueba la
  convergencia y destruye.
- **Cierre:** muestra el resultado de cada paso y siempre detiene el contenedor.

El emulador cubre sobre todo el **plano de control**: no ejecuta contenedores ECS ni el motor de
RDS, y no evalúa IAM. Un fallo o una deriva pueden deberse a su fidelidad. Nunca sustituye a la
validación en AWS (D-9C-AWS). La mensajería AWS se prueba en la CI con LocalStack.

## Genesis y Apocalypse en AWS

`genesis.yml` y `apocalypse.yml` son los mismos workflows para Azure y AWS: el proveedor sale de la
definición fusionada en `main`, nunca de una entrada del despacho.

1. **`validate`:** valida la definición y las protecciones del Environment y publica el proveedor. En
   AWS añade el rol, la región y la cuenta.
2. **`execute`:** antes de autenticarse, comprueba que las variables del Environment (`AWS_ROLE_ARN`,
   `AWS_REGION`, `AWS_ACCOUNT_ID`) coinciden exactamente con la definición. Después asume el rol de la
   reserva con `aws-actions/configure-aws-credentials` v6.3.0, fijada por commit, por OIDC y sin
   credenciales guardadas.
3. **Diagnóstico de aislamiento:** ejecuta el del incremento 2b.
4. **Etapa:** `Invoke-EnvironmentWorkflow.ps1` despacha a `Invoke-AwsEnvironment.ps1`, que tiene los
   mismos modos que el adaptador de Azure:
   - `Build`, `Restore` e `Initialize`: snapshot de `hosting-aws` y `aws` con sus módulos, y custodia
     en S3;
   - `Prepare`, `Apply` y `Sync`: plan revisado, apply desde `main` y reconciliación;
   - `UpdateInputs`.
   - **`BindMessaging`**: en AWS no reescribe nada, porque la mensajería usa los roles de tarea que
     crea hosting, con nombres deterministas. Comprueba que cada rol publicador o consumidor existe en
     las salidas del estado verificado de hosting.
   - **`Quiesce`** (Apocalypse): pone a cero los servicios ECS de la instancia, detiene las tareas en
     ejecución y espera, como máximo diez minutos, a que nada corra. La seguridad antes de destruir lo
     vuelve a comprobar antes de cada plan de baja.

## Entrega AWS: imágenes y tareas de base de datos

`AwsApplicationDelivery.psm1` sigue las etapas de la entrega de Azure, con el journal (`delivery.json`)
en la custodia S3 de la instancia:

| Etapa | Qué hace |
| --- | --- |
| `Artifacts` | Descarga y verifica los candidatos, y copia cada imagen a ECR **por digest** con el protocolo OCI y las credenciales de `ecr get-login-password`. El destino es `<registro>/<prefijo>/<artefacto>@sha256:…`, la misma regla que el exportador de hosting. |
| `PrepareMaintenance` y `ApplyMaintenance` | Plan revisado de hosting con `maintenance_jobs_enabled`, sin rollout. |
| `DatabaseCredentials`, `Migrations`, `DatabaseAccess` y `KeycloakDatabase` | Las tareas en el orden de la [ADR 0024](adr/0024-credenciales-de-base-de-datos-en-aws.md). Cada una exige que las anteriores hayan terminado bien, y `KeycloakDatabase` solo existe con identidad integrada. |

Cada tarea se ejecuta con `ecs:RunTask` y las mismas garantías que los jobs de Azure:

- **Antes de ejecutarla**, se compara su task definition registrada con la esperada (familia
  `<prefijo>-<tarea>`, imagen, comando y, en las tareas de base de datos, el
  `HEXAGON_DATABASE_BOOTSTRAP` incrustado).
- **Intención durable:** el journal guarda la intención antes del `RunTask`, que lleva el intento en
  `--started-by`. Si la respuesta se pierde, la tarea se adopta por esa marca y nunca se lanza otra;
  con más de una candidata, se bloquea.
- **Resultado:** solo cuenta como éxito una tarea `STOPPED` con `EssentialContainerExited` y código 0
  en el contenedor `maintenance`. Un fallo detiene la entrega hasta investigarlo.

## Entrega AWS: identidad, activación, SPA y verificación

`delivery.yml` es el mismo workflow para Azure y AWS. El proveedor sale del target de la definición
de la instancia: con AWS comprueba las variables del Environment (`AWS_ROLE_ARN`, `AWS_REGION` y
`AWS_ACCOUNT_ID`) y asume el rol de la reserva por OIDC, igual que Genesis. La etapa
`DatabaseCredentials` solo existe en AWS.

| Etapa | Qué hace |
| --- | --- |
| `PrepareIdentity` y `ApplyIdentity` | Solo con Keycloak integrado y con `keycloak-database` terminada. Plan revisado de hosting con `keycloak_rollout_enabled`. |
| `PrepareActivation` y `ApplyActivation` | Exigen todas las tareas de base de datos y, con Keycloak integrado, su servicio estable y el descubrimiento OIDC correcto bajo `/auth`. Plan revisado con `application_rollout_enabled`. |
| `PublishWeb` | Comprueba el backend, compone el SPA verificado con su configuración pública y lo sube al bucket privado. Después invalida CloudFront y espera a que termine. |
| `VerifyServing` | Descarga cada archivo por CloudFront y comprueba contenido, tipos, cabeceras y el fallback del SPA; vuelve a comprobar el backend y guarda la evidencia en la custodia. |

Detalles que conviene conocer:

- **Destino del SPA:** el bucket `<prefijo>-web-<cuenta>` y la distribución que registró el root de
  hosting. Cualquier otro se rechaza.
- **Orden y caché:** primero los recursos y al final `index.html`, `runtime-config.json` y
  `hexagon-deployment.json`, que van con `no-store`; el resto, con `no-cache`. Los objetos que ya no
  pertenecen al despliegue se borran.
- **Cabeceras de seguridad:** `nosniff`, `no-referrer` y HSTS salen de una política de cabeceras de
  respuesta de CloudFront, en todas las rutas. `staticwebapp.config.json` es un archivo de Azure y no
  se publica.
- **Salud del backend:** cada servicio ECS activo, con un solo despliegue `COMPLETED`, las réplicas
  mínimas en ejecución y la imagen esperada. La API, además, con destinos `healthy` en el balanceador;
  un worker con balanceador se rechaza.
- **Evidencia:** una verificación nueva sustituye a la anterior. Si falla, la entrega queda en
  `Published`, sin evidencia. `applicationVerified` sigue en `false`: la evidencia dice qué se vio en
  ese momento, no que el servicio siga disponible.

## Aceptación en AWS

`PrepareAcceptance` y `Acceptance` siguen el mismo protocolo que en Azure, con las piezas de AWS en
`AwsAcceptance.psm1`:

1. **`PrepareAcceptance`** exige la evidencia de servicio vigente. Guarda en `consents/` el
   consentimiento de limpieza: los dos roots, identificados por su prefijo corto, con el linaje y el
   serial de su estado y la lista exacta de recursos.
2. **`Acceptance`** exige ese consentimiento y la confirmación `TEST AND CLEANUP <producto> <ambiente>
   <instancia>`. Ejecuta la tarea `acceptance-seed` (la imagen de la API con `--seed-acceptance-only`
   y el fixture de la instancia), el navegador autenticado y la limpieza.
3. **La evidencia se guarda antes de borrar nada**, también si el recorrido falla.
4. **La limpieza** detiene los servicios (`Quiesce`) y destruye los roots en orden inverso. Cada plan
   de baja debe borrar exactamente los recursos consentidos: ni uno más, ni uno menos.

El bucket del estado, su clave KMS, el proveedor OIDC y los roles de la reserva quedan fuera de la
limpieza, como en Apocalypse.

## Ámbito de una instancia

- **Etiquetas:** las raíces `hosting-aws` y `aws` de cada ambiente ponen, con `default_tags`,
  `hexagon:product`, `hexagon:environment`, `hexagon:instance` y, en una reserva,
  `hexagon:name-prefix`. Fuera de una reserva, `instance_id` vale `persistent`.
- **Roles IAM:** con `workload_boundary_arn`, el hosting AWS pone ese boundary en todos sus roles, y
  la reserva no permite crear roles sin él.
- **Nombres de mensajería:** los nombres físicos de la política AWS SNS/SQS (topics, colas y alias
  KMS) deben empezar por el prefijo corto de la instancia; el adaptador del incremento 3 lo
  comprobará.
