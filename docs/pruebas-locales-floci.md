# Pruebas locales con Floci

Floci es la herramienta oficial de Hexagon para probar y desplegar en local, en AWS y en Azure
([ADR 0026](adr/0026-floci-como-plataforma-local.md)). Mientras estén suspendidos los despliegues
reales, por falta de minutos de GitHub Actions, estas pruebas son la garantía de la plataforma.

## Qué se prueba hoy

| Prueba | Comando | Qué demuestra |
| --- | --- | --- |
| Infraestructura AWS | `pwsh ./tests/Invoke-FlociRoots.ps1 -Cloud Aws` | El root `hosting-aws` se aplica (estado inicial, y después mantenimiento y rollout), converge y se destruye sin dejar nada. |
| Infraestructura Azure | `pwsh ./tests/Invoke-FlociRoots.ps1 -Cloud Azure` | Lo mismo con el root `hosting-azure`. |
| Root de mensajería AWS | `pwsh ./tests/Invoke-FlociRoots.ps1 -Cloud Aws -Roots Messaging` | SNS, SQS, KMS y permisos por workload desde el contrato; convergencia y destrucción. |
| Entrega local AWS | `pwsh ./tests/Invoke-FlociRoots.ps1 -Cloud Aws -Backend <backend>` | Imágenes OCI por digest, credenciales, migraciones, permisos, rollout, salud, API y SPA de prueba por CloudFront; retirada al terminar. |
| Mensajería local AWS | `pwsh ./tests/Test-LocalMessagingRuntime.ps1 -Provider aws-sns-sqs` | La topología SNS/SQS generada desde el contrato del backend se crea en Floci y queda lista. |
| Operaciones AWS | `$env:HEXAGON_RUN_BROKER_TESTS = '1'; dotnet test operations/Hexagon.Messaging.Operations.Tests` | Reproceso de mensajes en SQS y lectura de Secrets Manager contra Floci. |

Ninguna corre en la CI: se ejecutan en local antes de abrir un PR que toque lo que prueban, y el
resultado va en el PR. El core y la plantilla ML usan Floci en sus pruebas integrales de AWS SNS/SQS
con `Testcontainers.Floci`.

## Requisitos

- Docker en marcha. La prueba descarga las imágenes fijadas: `floci/floci:2.3.0`,
  `floci/floci-az:0.15.0` y `hashicorp/terraform:1.17.1`.
- Unos 4 GB de memoria libres para el emulador y los contenedores que levanta.
- Acceso a internet la primera vez, para las imágenes y los proveedores de Terraform. Los
  proveedores quedan en el volumen Docker `hexagon-terraform-plugins` y se reutilizan.

No necesita credenciales de AWS ni de Azure y no toca ninguna cuenta real.

## Backend para la entrega AWS

Usar un checkout de prueba generado desde la plantilla ML, con el nombre del producto ya cambiado
y el proveedor `AwsSnsSqs`. El script lee sus manifiestos `.hexagon/`, compila la API y cada Worker,
y compila la imagen de mantenimiento de este repositorio. Requiere .NET 10, Git, AWS CLI y acceso
al feed del core para restaurar el backend. El token se entrega mediante la variable de entorno
indicada por la plantilla.

```powershell
pwsh ./tests/Invoke-FlociRoots.ps1 -Cloud Aws -Backend <backend>
```

Las imágenes quedan en `artifacts/floci-images/<commit-backend>-<commit-devops>/` y se reutilizan
para esos commits. Si se cambia código sin confirmar, añadir `-Rebuild` para recompilarlas.
La prueba entrega las imágenes con el código de producción de `Publish-AwsOciArchive`, registra
las tareas ECS y ejecuta `database-credentials`, `migrations` y `database-access`, en ese orden.
Los bindings de SNS/SQS se incorporan al entorno de cada workload antes del mantenimiento.

El host del proxy PostgreSQL usa un alias Docker terminado en `.rds.amazonaws.com`. Esto permite
validar la configuración pública del bootstrap y resolver el destino dentro de la red de la prueba.
El puerto se toma de RDS, que Floci publica en su rango de proxies. Se conserva `SSL Mode=Require`;
Floci termina TLS en el proxy. El formato del host, el puerto y la conexión deben coincidir en
las tareas y en los secretos de runtime.

Para la entrega, CloudFront usa el nombre del contenedor de Floci como destino del listener
local del ALB. Ese nombre exacto se permite en `FLOCI_SERVICES_CLOUDFRONT_ALLOWED_PRIVATE_ORIGIN_HOSTS`.
La copia temporal conserva el listener, sus reglas y sus targets. Este ajuste evita depender del
DNS anunciado por el emulador y permite su origen privado en el cliente HTTP de CloudFront.
La opción del emulador se define en su
[configuración de CloudFront 2.3.0](https://github.com/floci-io/floci/blob/2.3.0/src/main/java/io/github/hectorvent/floci/config/EmulatorConfig.java).

La SPA es un bundle mínimo generado por la prueba. Se comparan los hashes de su entrada,
`runtime-config.json` y una ruta con fallback. La entrada y la configuración se sirven desde la
distribución principal. Floci 2.3.0 almacena las CloudFront Functions, pero carece de ejecución
JavaScript. Por eso, el fallback se comprueba en una distribución estática adicional, creada solo
en la copia temporal, que usa respuestas de error 403/404 hacia `/index.html`. Comparte el bucket y
su OAC, con autorización para ambos ARN. La distribución principal conserva sus comportamientos
de API y SPA. Después de publicar se verifica que un 404 de la API siga siendo ProblemDetails.

`Test-Repository.ps1` ejecuta por separado el JavaScript real extraído del módulo Terraform para
comprobar rutas SPA y archivos estáticos. La ejecución de esa función en el edge de CloudFront
requiere validación en AWS. La API se comprueba por su respuesta HTTP y se comprueba también la
salud de los servicios. La autenticación interactiva con Keycloak y el frontend Angular completo
requieren su propia aceptación.

## Ejecución comprobada el 14 de noviembre de 2026

El recorrido `-Cloud Aws -Backend <backend>` terminó con código 0 usando un backend de prueba
generado de la plantilla ML en `38b8e0e`, renombrado a `FlociProbe` con `AwsSnsSqs`.
Las cuatro imágenes OCI se construyeron en el diagnóstico inicial y se reutilizaron al verificar
las correcciones de configuración y entrega.

| Comprobación | Resultado |
| --- | --- |
| Infraestructura, mensajería, bindings y copia OCI por digest | Passed |
| `database-credentials`, `migrations`, `database-access` | Passed |
| Rollout, salud de API y Workers, API por CloudFront | Passed |
| Entrada SPA y configuración pública desde la distribución principal | Passed |
| Ruta SPA desde el sustituto estático de fallback | Passed |
| 404 de la API después de publicar, con ProblemDetails | Passed |
| Destrucción de mensajería y hosting, estados vacíos | Passed |

`Test-Repository.ps1` pasó con 12 pruebas Python, 50 pruebas unitarias .NET, 7 pruebas Node y
56 casos Terraform, además de las suites PowerShell. Entrega AWS ejecutó 36 aserciones y
publicación/salud AWS ejecutó 93. La prueba Node de CloudFront ejecuta el JavaScript del módulo;
la comprobación del sustituto en Floci cubre la ruta SPA sin extensión.

## Cómo funciona

1. **Emulador.** Arranca Floci en `127.0.0.1`, en una red Docker propia de la prueba y con el
   socket de Docker montado (decisión del dueño), para que los servicios que Floci respalda con
   contenedores reales funcionen: el registro de ECR y ACR, y PostgreSQL de RDS y de Azure.
2. **Copia temporal.** Copia `terraform/` sin los directorios `.terraform` a
   `artifacts/floci-<nube>-<id>/`, con backend local. El estado real nunca se toca.
3. **Terraform en Linux.** Ejecuta la imagen oficial de Terraform dentro del espacio de red del
   emulador. En AWS usa el endpoint `http://localhost.floci.io:4566`: ese dominio y sus subdominios
   resuelven a `127.0.0.1`, así que S3 y el prefijo de cuenta de S3 Control llegan a Floci. En
   Azure confía en el certificado del emulador, porque el proveedor `azurerm` exige HTTPS.
4. **Recorrido.** Estado inicial; después `maintenance_jobs_enabled` y
   `application_rollout_enabled`; plan de convergencia; destrucción, que corre aunque falle un
   `apply`, y comprobación de que el estado queda vacío.
5. **Limpieza.** Elimina el emulador, los contenedores que creó y su red. La copia temporal queda
   para revisarla; no contiene credenciales.

Resultado: cada paso aparece como `Passed`, `Failed`, `Applied` (sustituto) o `Drift`. El script
termina con error si algún paso falla.

## Sustitutos

Floci no tiene todos los servicios que usan los módulos. Cuando falta uno, la copia temporal lo
sustituye. Cada sustituto busca el texto exacto del módulo y detiene la prueba si no lo encuentra,
para que un cambio del módulo obligue a revisarlo.

| Nube | Sustituto | Por qué | Se retira cuando |
| --- | --- | --- | --- |
| AWS | La lista de prefijos `com.amazonaws.global.cloudfront.origin-facing` pasa a ser una lista propia | Floci 2.3.0 solo trae las listas administradas de S3 y DynamoDB, y rechaza los nombres reservados | Floci 2.4.0 o posterior sea elegible: permite configurar más listas administradas |
| AWS | El origen `applications` de CloudFront usa `custom_origin_config` hacia el balanceador en lugar del VPC origin | Floci no implementa los VPC origins de CloudFront | Floci los implemente |
| AWS, entrega | El dominio del origen `applications` usa el contenedor de Floci, permitido por nombre exacto como origen privado | El ALB escucha dentro de Floci y su nombre DNS anunciado carece de resolución Docker; CloudFront limita los orígenes privados | Floci resuelva y enrute los dominios de sus ALB desde CloudFront |
| AWS, entrega | Distribución estática adicional con respuestas de error 403/404 para comprobar el fallback sobre el mismo bundle S3 | Floci almacena las CloudFront Functions sin ejecutar su JavaScript | Floci ejecute la función asociada al comportamiento estático |
| AWS | `ignore_changes = [code]` en la función de CloudFront | Floci devuelve el código en base64; Terraform lo reescribiría en cada `apply` y la publicación falla | Floci devuelva el código tal como se envió |
| Azure | PostgreSQL con administrador y contraseña locales | Floci AZ exige un administrador con contraseña; Hexagon usa solo Entra ID | Floci AZ admita servidores solo con Entra ID |
| Azure | Sin las asignaciones del rol `AcrPull` | Floci AZ 0.15.0 no tiene asignaciones de rol: su RBAC aún no está en una versión publicada | Una versión elegible de Floci AZ incluya RBAC |
| Azure | Sin el administrador Entra ID de la identidad de mantenimiento en PostgreSQL | Floci AZ no tiene administradores Entra en PostgreSQL | Floci AZ los implemente |
| Azure | Sin workspace de Log Analytics ni su vínculo con el entorno de Container Apps | El proveedor consulta los workspaces borrados antes de crear uno, y Floci AZ no tiene esa API | Floci AZ la implemente |
| Azure | Sin los jobs de Container Apps de mantenimiento (`maintenance_jobs` queda vacío) | Floci AZ tiene Container Apps pero no sus jobs | Floci AZ implemente `Microsoft.App/jobs` |
| Azure | Static Web Apps pasa a ser un valor fijo con el mismo id y nombre de host | Floci AZ no tiene Static Web Apps | Floci AZ la implemente |

## Derivas conocidas

El plan de convergencia puede mostrar cambios que solo existen en el emulador. La prueba los marca
como `Drift (emulator fidelity gap)` y no falla.

| Nube | Deriva | Causa |
| --- | --- | --- |
| AWS | `aws_db_instance`: `storage_type` `gp2` → `gp3` y `ca_cert_identifier` | Floci RDS no devuelve esos atributos como se configuraron |
| Azure | `azurerm_postgresql_flexible_server` se reemplazaría: no devuelve `delegated_subnet_id`, `private_dns_zone_id` ni `public_network_access_enabled = false`; arrastra a su base de datos, al `database_bootstrap` y a la cadena de conexión de la API | Floci AZ no modela la red privada de PostgreSQL |
| Azure | `azurerm_container_registry`: `role_assignment_mode` | Floci AZ no devuelve el atributo |

Una deriva en otro recurso es una señal a investigar.

## Límites

- **No acredita la nube.** Floci no reproduce la red de AWS o Azure, los límites de los servicios,
  todos los permisos ni los tiempos reales. Con los despliegues reales reanudados, el primer
  despliegue en cada nube sigue siendo obligatorio.
- **Lo sustituido no se prueba.** Los VPC origins de CloudFront, Static Web Apps, Log Analytics, la
  autenticación solo con Entra ID de PostgreSQL y las asignaciones de rol `AcrPull` y los jobs de
  mantenimiento de Azure quedan sin cubrir en local.
- **Azure tiene cobertura parcial.** Floci AZ 0.15.0 ofrece Service Bus mediante la API de datos,
  pero carece de la API ARM de namespaces, jobs de Container Apps y RBAC. `-Roots Messaging` lo
  informa como `Not covered`; la entrega completa con `-Backend` requiere AWS.
- **Custodia y aceptación.** La prueba de entrega usa custodia en memoria y backend Terraform local.
  El ciclo distribuido con custodia remota y la aceptación autenticada quedan sujetos a sus
  pruebas específicas y a la validación real del [ADR 0026](adr/0026-floci-como-plataforma-local.md).

## Actualizar Floci

1. Elegir una versión publicada hace al menos dos semanas.
2. Cambiarla en `tests/Invoke-FlociRoots.ps1`, en `scripts/LocalMessaging.psm1` y en las pruebas
   .NET que la fijan, en DevOps, el core y la plantilla ML.
3. Ejecutar las pruebas de esta guía y retirar los sustitutos que la versión nueva ya no necesite.
4. Anotar el resultado en el PR.
