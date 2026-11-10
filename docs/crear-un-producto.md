# Crear el repositorio DevOps de un producto

Un producto Hexagon tiene repositorios de aplicación separados y una instancia propia de esta
plantilla:

```text
hexagon-hr-ng         ─┐
                       ├──> hexagon-hr-devops
hexagon-hr-dotnet-ml  ─┘
```

Esa separación aísla permisos, estado, radio de impacto, promoción y ciclo de vida. Esta plantilla
no se usa como un repositorio central que aplique todos los productos.

Tampoco se elige entre una plantilla DevOps `-ml` y otra `-ms`. El producto comienza con el monolito
modular y conserva esta misma instancia si después extrae servicios. Así no se duplican módulos ni
se trasladan estados y recursos por un cambio de arquitectura backend.

## 1. Crear desde la plantilla

Desde GitHub, usa **Use this template**, o ejecuta:

```powershell
gh repo create ajunquit/hexagon-hr-devops `
  --private `
  --template ajunquit/hexagon-template-devops `
  --clone
```

El repositorio nuevo conserva esta estructura, pero sus descriptores y decisiones propias se
mantienen en ramas y PR independientes de la plantilla.

## 2. Fijar los contratos de `dev`

```powershell
pwsh ./scripts/New-ProductEnvironmentDescriptor.ps1 `
  -Product hexagon-hr `
  -Environment dev `
  -BackendRepository ajunquit/hexagon-hr-dotnet-ml `
  -BackendRef <commit-o-tag> `
  -FrontendRepository ajunquit/hexagon-hr-ng `
  -FrontendRef <commit-o-tag>
```

Aunque se acepte una rama como entrada, el resultado guarda el commit de 40 caracteres. El script:

1. resuelve la referencia con GitHub;
2. descarga los manifiestos de ese commit;
3. resuelve y valida cada JSON Schema desde el mismo commit;
4. exige que `product` y `component` coincidan;
5. calcula el `SHA-256` de los bytes descargados;
6. escribe y valida `products/hexagon-hr/environments/dev/descriptor.json`.

Se puede omitir frontend o backend solo cuando el producto realmente no tenga ese componente. Los
parámetros `Repository` y `Ref` siempre se proporcionan juntos.

## 3. Definir la política de mensajería

El manifiesto backend decide el proveedor. DevOps añade en el mismo ambiente una sola política:

- `azure-service-bus-policy.json` si declara `azure-service-bus`;
- `aws-sns-sqs-policy.json` si declara `aws-sns-sqs`;
- `rabbitmq-policy.json` si declara `rabbitmq`.

Después materializa entradas para el root correspondiente. Por ejemplo, para AWS:

```powershell
pwsh ./scripts/Export-AwsSnsSqsTerraformInputs.ps1 `
  -Descriptor products/hexagon-hr/environments/dev/descriptor.json `
  -Policy products/hexagon-hr/environments/dev/aws-sns-sqs-policy.json `
  -Output terraform/environments/dev/aws/aws-sns-sqs.auto.tfvars.json
```

La política física sí se versiona; el archivo `*.auto.tfvars.json` generado no. Los principal IDs
de Azure, los role names de AWS y los user names de RabbitMQ no son secretos, pero las credenciales
nunca entran al repositorio.

RabbitMQ se materializa con el script y root equivalentes:

```powershell
pwsh ./scripts/Export-RabbitMqTerraformInputs.ps1 `
  -Descriptor products/hexagon-hr/environments/dev/descriptor.json `
  -Policy products/hexagon-hr/environments/dev/rabbitmq-policy.json `
  -Output terraform/environments/dev/rabbitmq/rabbitmq.auto.tfvars.json
```

Sus usuarios de workload deben existir previamente. Terraform administra sus permisos sin guardar
contraseñas; las connection strings llegan desde el gestor de secretos del despliegue.

## 4. Arrancar la mensajería local

Desde la instancia DevOps, genera la topología del proveedor y los bindings del backend. Conviene
usar la política de `dev` para reproducir también la elección de DLQ/DLX de cada cola:

```powershell
pwsh ./scripts/Start-LocalMessaging.ps1 `
  -BackendPath ../hexagon-hr-dotnet-ml `
  -Policy products/hexagon-hr/environments/dev/rabbitmq-policy.json
```

Para Azure añade `-AcceptLicense`; para AWS o RabbitMQ no. Luego ejecuta `aspire run` en el backend.
La guía completa está en [`local/README.md`](../local/README.md).

## 5. Promover a otros ambientes

Ejecuta el mismo comando con `-Environment staging` y después con `prod`, usando el commit que se
promoverá. Promover no significa volver a compilar ni leer `main`: cambia el descriptor mediante un
PR y aplica exactamente los artefactos y requisitos asociados a ese commit.

Hasta la fase 9 no existe un pipeline de despliegue. Cada ambiente conserva su propio descriptor,
política, backend remoto y estado.

## 6. Validar

En 9B adapta también `.config/product.json` al identificador del producto. Incorpora los workflows
de cada aplicación y configura los accesos de lectura privados según [CI y artefactos](ci-y-artefactos.md).

```powershell
pwsh ./scripts/Test-Repository.ps1

pwsh ./scripts/Test-ProductEnvironmentDescriptor.ps1 `
  -Descriptor products/hexagon-hr/environments/dev/descriptor.json `
  -VerifySources
```

La primera comprobación es local. La segunda vuelve a descargar cada manifiesto del commit fijado y
detecta si el contenido, su esquema o su identidad difieren.

## Qué no se configura todavía

El [bootstrap de plataformas](bootstrap-plataformas.md) permite validar el YAML, revisar y aplicar
las etapas State/Access/GitHub, migrar el estado y verificar mediante diagnóstico federado. Adapta
primero `.config/product.json` y el ejemplo; usa sus comandos, planes revisados y permisos del
operador. La plantilla no aplica infraestructura automáticamente al crear el repositorio.

- clúster RabbitMQ compartido;
- Kubernetes y las referencias de hosting ajenas a Azure;
- pipelines de entrega Genesis/Apocalypse y promoción; el diagnóstico federado ya está implementado.

Azure Service Bus, AWS SNS/SQS y RabbitMQ ya tienen módulos y políticas; la instancia del producto
todavía debe dar sus valores reales e identidades. Ninguna capacidad se crea desde el runtime de la
aplicación.

La fase 9A añade la [referencia de hosting Azure](hosting-azure.md): Container Apps, PostgreSQL,
Static Web Apps, dominio administrado y Log Analytics, junto a contratos y artefactos inmutables.
9B añade CI y artefactos verificables. El despliegue cloud acreditado permanece en 9C.
