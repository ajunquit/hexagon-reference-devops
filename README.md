# hexagon-template-devops

Plantilla reutilizable de infraestructura, despliegue y operación para un producto Hexagon.
Cada producto crea su propio repositorio desde esta plantilla, por ejemplo `hexagon-hr-devops`.
Ese repositorio es la fuente de verdad de sus recursos físicos y de sus políticas por ambiente.

La plantilla no contiene código de frontend o backend, estado de IaC, credenciales ni nombres de
recursos de un producto real.

## Responsabilidades

```text
Frontend ── FrontendHostingRequirements ─┐
                                         ├──> repositorio DevOps del producto
Backend  ── Backend*Requirements ────────┘        │
                                                  ├── infraestructura física
                                                  ├── bindings por workload
                                                  └── operación por ambiente
```

| Aplicaciones | DevOps del producto |
| --- | --- |
| Declaran requisitos lógicos bajo `.hexagon/` | Crea y opera recursos físicos |
| Versionan sus contratos | Fija repositorio, commit y `SHA-256` aplicado |
| Validan bindings al arrancar | Entrega configuración, identidades y secretos por referencia |
| No crean topología en runtime | Define políticas por ambiente y entidad |

Los recursos compartidos por varios productos —por ejemplo una zona DNS organizacional o un plano
central de observabilidad— pertenecerán a un futuro repositorio de plataforma. No se agregan a un
repositorio de producto ni a esta plantilla.

## Una sola plantilla durante todo el ciclo de vida

No existen `hexagon-template-devops-ml` y `hexagon-template-devops-ms`. Todo producto comienza con
un backend de monolito modular, según
[BE-0003](https://github.com/ajunquit/hexagon-core-dotnet/blob/main/docs/adr/BE-0003-arquitectura-limpia-un-proyecto-por-capa.md),
y crea una única instancia como `hexagon-hr-devops`.

Si una necesidad demostrada obliga a extraer uno o más microservicios, la misma instancia DevOps
incorpora sus nuevas unidades desplegables y conserva sus estados, ambientes y recursos. La
arquitectura de despliegue se expresa mediante contratos versionados y composiciones de Terraform;
no se deduce del nombre del repositorio ni exige copiar la infraestructura a otra plantilla.

La decisión completa está en el
[ADR 0004](docs/adr/0004-una-plantilla-devops-con-monolito-modular-inicial.md).

## Estado actual

9C incorpora [reservas efímeras y Genesis/Apocalypse](docs/ciclo-efimero-azure.md), con identidad y
estado aislados, plan/revisión/aplicación por etapa y recuperación. Se prueba localmente y por
protocolo. La [entrega verificable](docs/entrega-aplicaciones-azure.md) conecta candidatos de CI,
migraciones, permisos y activación de API/Workers. La [publicación SPA y salud](docs/publicacion-spa-y-salud.md)
añade observación de contenido y workloads. La aceptación y limpieza consentida están implementadas; falta su ejecución Azure real.

La preparación de 9C incorpora el [adaptador Terraform/Azure](docs/adaptador-ciclo-azure.md),
con snapshot confiable, inventario remoto y recuperación. Está probado localmente y con simulación
del protocolo Azure; reservas y workflows se detallan en la guía del ciclo. El recorrido integral
y la verificación cloud real siguen pendientes.

La fase 9B añade [CI y artefactos verificables](docs/ci-y-artefactos.md) en los tres componentes,
incluidas pruebas locales de integración y candidatos inmutables desde main. No despliega recursos;
el ambiente efímero y la promoción permanecen en 9C/9D.

La fase 9A incorpora la [referencia de hosting Azure](docs/hosting-azure.md): Container Apps,
Static Web Apps, PostgreSQL privado, identidades y jobs separados, contratos de hosting y registro
`ApplicationRelease` de artefactos inmutables. Se verifica localmente y con mocks; 9B incorpora CI,
y el ambiente efímero real y la promoción corresponden a 9C y 9D.

Las fases 3 a 8 establecen:

- un repositorio DevOps por producto, generado desde esta plantilla;
- el descriptor inmutable `ProductEnvironment` v1;
- validación local y verificación opcional de los manifiestos en GitHub;
- Terraform como única herramienta de IaC;
- límites separados para módulos de Azure, AWS y RabbitMQ;
- carpetas independientes para `dev`, `staging`, `prod` y desarrollo local;
- contrato DevOps `AzureServiceBusPolicy` v1 por ambiente;
- bootstrap Azure ejecutable con planes revisados, estado remoto protegido, contenedores e
  identidades por ambiente y diagnóstico federado;
- topología Terraform de Azure Service Bus con topics, suscripciones, filtros, DLQ incorporada y
  RBAC mínimo por workload;
- bindings sin secretos para el adaptador Azure del backend;
- contrato DevOps `AwsSnsSqsPolicy` v1 por ambiente;
- bootstrap AWS para estado S3 cifrado, versionado y con lockfile;
- topología Terraform de SNS/SQS con filtros, Raw Message Delivery, RBAC mínimo y DLQ opcional por
  cola;
- bindings sin secretos para el adaptador AWS del backend;
- contrato DevOps `RabbitMqPolicy` v1 por ambiente;
- topología Terraform de RabbitMQ con virtual host, exchanges, colas quorum, bindings, límite de
  entrega y DLX/DLQ opcional por cola;
- permisos mínimos para usuarios preexistentes y credenciales administrativas efímeras.
- topología local de los tres proveedores generada desde el contrato backend y la política DevOps;
- bindings locales versionados por contrato, ignorados por Git y separados por workload;
- un AppHost que orquesta aplicaciones pero no crea infraestructura de mensajería;
- políticas operativas por consumidor, alertas nativas y operadores separados de las aplicaciones;
- inspección sin cuerpos y recuperación acotada desde DLQ conservando la identidad del inbox.

La [guía de operación](docs/operacion-mensajeria.md) describe políticas, métricas, retención,
cuarentena y recuperación. La herramienta .NET de `operations/` es código operativo de DevOps,
independiente del backend y de los paquetes `Hexagon.Core.*`.

El clúster RabbitMQ, el hosting de Prometheus/Alertmanager, Kubernetes y despliegues cloud todavía no
están implementados. Se incorporarán por fases y con sus propias decisiones.

## Estructura

```text
contracts/schemas/                 contratos propiedad de DevOps
docs/adr/                          decisiones del proyecto
examples/                          ejemplos no desplegables
terraform/
├── bootstrap/{azure,aws}/         estado remoto por proveedor
├── environments/{dev,staging,prod}/{azure,aws,rabbitmq}/
└── modules/messaging/
    ├── azure-service-bus/
    ├── aws-sns-sqs/
    └── rabbitmq/
local/                             topología local multiproveedor y artefactos ignorados
operations/                        herramienta de inspección y recuperación; pruebas aisladas
products/<producto>/environments/  descriptores y políticas por ambiente
scripts/                           validación y generación determinista
```

La organización se inspira en el laboratorio
[`movieops`](https://github.com/ajunquit/movieops): módulos separados de ambientes, scripts
operables y ADR. No se copia su aplicación ni se presupone Kubernetes o un proveedor cloud.

## Crear el repositorio DevOps de un producto

La guía completa está en [docs/crear-un-producto.md](docs/crear-un-producto.md). El primer paso es
crear un repositorio desde esta plantilla:

```powershell
gh repo create ajunquit/hexagon-hr-devops `
  --private `
  --template ajunquit/hexagon-template-devops `
  --clone
```

Después se fija un commit de cada aplicación para cada ambiente:

```powershell
pwsh ./scripts/New-ProductEnvironmentDescriptor.ps1 `
  -Product hexagon-hr `
  -Environment dev `
  -BackendRepository ajunquit/hexagon-hr-dotnet-ml `
  -BackendRef main `
  -FrontendRepository ajunquit/hr-ng `
  -FrontendRef main
```

El script resuelve cada referencia a un commit completo, descarga y valida los manifiestos contra
su esquema, calcula su `SHA-256` y escribe
`products/hexagon-hr/environments/dev/descriptor.json`. Repite el comando para `staging` y `prod`
con los commits que se promoverán; una rama mutable nunca se aplica directamente.

## Comprobaciones

```powershell
# Contrato y convenciones locales; no necesita acceso cloud.
pwsh ./scripts/Test-Repository.ps1

# Además comprueba que cada archivo remoto aún coincide con el commit y SHA declarados.
pwsh ./scripts/Test-ProductEnvironmentDescriptor.ps1 `
  -Descriptor products/hexagon-hr/environments/dev/descriptor.json `
  -VerifySources
```

`-VerifySources` necesita `gh auth login` si los repositorios de aplicación son privados.

La mensajería local se inicia desde esta instancia, no desde el AppHost:

```powershell
pwsh ./scripts/Start-LocalMessaging.ps1 `
  -BackendPath ../hexagon-hr-dotnet-ml `
  -Policy products/hexagon-hr/environments/dev/rabbitmq-policy.json
```

Después se ejecuta `aspire run` en el backend. Para Azure se añade `-AcceptLicense`. Consulta la
[guía local](local/README.md) para generar sin iniciar Docker o detener los contenedores.

Para un backend que elige Azure Service Bus, después se crea su política por ambiente y se
materializan las entradas ignoradas por Git:

```powershell
pwsh ./scripts/Export-AzureServiceBusTerraformInputs.ps1 `
  -Descriptor products/hexagon-hr/environments/dev/descriptor.json `
  -Policy products/hexagon-hr/environments/dev/azure-service-bus-policy.json `
  -Output terraform/environments/dev/azure/azure-service-bus.auto.tfvars.json
```

La guía de [política de Azure Service Bus](docs/politica-azure-service-bus.md) explica el contrato,
el plan y la DLQ incorporada. No se ejecuta `apply` local contra ambientes compartidos.

Para un backend que elige AWS SNS/SQS, se usa la política y el root AWS equivalentes:

```powershell
pwsh ./scripts/Export-AwsSnsSqsTerraformInputs.ps1 `
  -Descriptor products/hexagon-hr/environments/dev/descriptor.json `
  -Policy products/hexagon-hr/environments/dev/aws-sns-sqs-policy.json `
  -Output terraform/environments/dev/aws/aws-sns-sqs.auto.tfvars.json
```

La [política de AWS SNS/SQS](docs/politica-aws-sns-sqs.md) decide el redrive y la DLQ
independientemente para cada cola.

Para un backend que elige RabbitMQ, se materializa su política en el root independiente:

```powershell
pwsh ./scripts/Export-RabbitMqTerraformInputs.ps1 `
  -Descriptor products/hexagon-hr/environments/dev/descriptor.json `
  -Policy products/hexagon-hr/environments/dev/rabbitmq-policy.json `
  -Output terraform/environments/dev/rabbitmq/rabbitmq.auto.tfvars.json
```

La [política de RabbitMQ](docs/politica-rabbitmq.md) decide el límite y DLX/DLQ por cola. Los
usuarios existen antes del `apply`; Terraform administra únicamente sus permisos mínimos.

## Documentación

- [Motor de ciclo de ambiente: inventario, planes y recuperación](docs/motor-ciclo-ambiente.md)
- [Bootstrap de plataformas: YAML, planes revisados, ejecución y verificación](docs/bootstrap-plataformas.md)
- [Genesis y Apocalypse: creación/destrucción por ambiente, diseño para 9C/9D](docs/genesis-y-apocalypse.md)
- [ADR 0012: Genesis y Apocalypse por ambiente](docs/adr/0012-genesis-y-apocalypse-por-ambiente.md)
- [Crear un producto DevOps](docs/crear-un-producto.md)
- [Contrato `ProductEnvironment` v1](docs/contrato-producto-ambiente.md)
- [Política `AzureServiceBusPolicy` v1](docs/politica-azure-service-bus.md)
- [Política `AwsSnsSqsPolicy` v1](docs/politica-aws-sns-sqs.md)
- [Política `RabbitMqPolicy` v1](docs/politica-rabbitmq.md)
- [Ruta de implementación](docs/ruta-plataforma.md)
- [Aceptación autenticada y limpieza consentida](docs/aceptacion-integral-azure.md)
- [ADR 0001: una instancia por producto](docs/adr/0001-una-instancia-devops-por-producto.md)
- [ADR 0002: Terraform](docs/adr/0002-terraform-como-herramienta-iac.md)
- [ADR 0003: referencias inmutables](docs/adr/0003-descriptores-inmutables-por-ambiente.md)
- [ADR 0004: una plantilla con monolito modular inicial](docs/adr/0004-una-plantilla-devops-con-monolito-modular-inicial.md)
- [ADR 0005: topología de Azure Service Bus desde contratos](docs/adr/0005-topologia-de-azure-service-bus-desde-contratos.md)
- [ADR 0006: topología de AWS SNS/SQS con redrive por cola](docs/adr/0006-topologia-de-aws-sns-sqs-con-redrive-por-cola.md)
- [ADR 0007: topología de RabbitMQ con DLX por cola](docs/adr/0007-topologia-de-rabbitmq-con-dlx-por-cola.md)
- [ADR 0008: topología local fuera del AppHost](docs/adr/0008-topologia-local-fuera-del-apphost.md)

La [publicación SPA y salud de hosting](docs/publicacion-spa-y-salud.md) incorpora PublishWeb/VerifyServing
con el candidato original y evidencia de archivos, configuración pública y API/Workers. Ya están
implementados el E2E autenticado y la limpieza con consentimiento previo, según [aceptación integral](docs/aceptacion-integral-azure.md). La ejecución Azure real sigue pendiente.
