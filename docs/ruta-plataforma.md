# Ruta de infraestructura y operación

Esta ruta continúa los contratos Aplicación–DevOps definidos por las plantillas frontend y backend.
Cada fase termina con pruebas y documentación antes de iniciar la siguiente.

## Estado

| Fase | Resultado | Estado |
| --- | --- | --- |
| 1A | Convención general Aplicación–DevOps | Fusionada en las aplicaciones |
| 1B | Contrato backend de mensajería | Fusionada en el backend |
| 1C | Contrato frontend de hosting | Fusionada en el frontend |
| 1D | Descriptor por producto y ambiente | Implementada aquí |
| 2 | Selección del proveedor al crear el backend | Fusionada en el backend |
| 3 | Plantilla DevOps y estructura IaC multiproveedor | Implementada aquí |
| 4 | Topología de Azure Service Bus | Implementada aquí |
| 5 | Topología de AWS SNS/SQS | Implementada aquí |
| 6 | Topología de RabbitMQ | Implementada aquí |
| 7 | Topología local fuera del AppHost | Implementada aquí |
| 8 | Operación de mensajería | Implementada aquí |
| 9 | Hosting, verificación automatizada y despliegue de frontend/backend | Pendiente |
| 10 | Estabilización y publicación | Pendiente |

## Fase 3

La fase 3 entregó la plantilla, la adopción de Terraform, el descriptor inmutable, validadores y
límites de carpetas. No modificó pipelines de frontend o backend ni creó infraestructura.

La plantilla es única para el producto. El backend inicial es un monolito modular; una futura
extracción de servicios evoluciona la misma instancia DevOps y sus contratos, sin crear variantes
`-ml` o `-ms` ni migrar el estado a otro repositorio.

Definition of Done:

- repositorio privado marcado como plantilla;
- una instancia y un estado aislados por producto;
- descriptores v1 validados localmente y verificables contra GitHub;
- estructura explícita por ambiente y proveedor;
- ADR de herramienta, límites y evolución monolito–microservicios;
- ninguna credencial, estado, plan o binding versionado.

## Fase 4

Azure Service Bus ya combina el contrato lógico del backend con una política DevOps v1 por
ambiente. Terraform crea namespace, topics, suscripciones, filtros explícitos y RBAC mínimo; entrega
bindings sin secretos y nunca concede `Manage` a la aplicación.

La DLQ es intrínseca a cada suscripción de Azure y no puede desactivarse. `MaxDeliveryCount` decide
cuándo llega allí un mensaje reintentado; la política decide además si la expiración lo envía a la
DLQ. Alertas, inspección y reproducción siguen reservadas para la fase 8.

Definition of Done:

- contrato `AzureServiceBusPolicy` v1 validado por esquema y semántica;
- correspondencia exacta con un manifiesto backend fijado por commit y SHA-256;
- topics y suscripciones por identificador lógico;
- `$Default` eliminado y routing `all` o `include` materializado explícitamente;
- autenticación local deshabilitada y RBAC Sender/Receiver en alcance mínimo;
- bootstrap de estado Azure con cifrado, versionado, recuperación y keys aisladas;
- roots separados para `dev`, `staging` y `prod`, con backend remoto parcial;
- pruebas Terraform sin credenciales ni recursos reales;
- ningún pipeline ni aprovisionamiento desde la API o los Workers.

## Fase 5

AWS SNS/SQS combina el contrato backend con `AwsSnsSqsPolicy` v1. Terraform crea topics, una cola
por Consumer, Raw Message Delivery, filtros por `EventType`, policies SNS→SQS e IAM de mínimo
privilegio. Cada cola decide explícitamente si crea DLQ y redrive.

Definition of Done:

- política AWS v1 validada por esquema, semántica y correspondencia exacta con backend;
- topics SNS y colas SQS estándar cifrados;
- routing `all` sin filtro o `include` por atributo `EventType`;
- policy de cada cola limitada a su topic;
- redrive y DLQ opcionales por Consumer, con retención mayor en la DLQ;
- roles distintos por workload y permisos Publish/Consume en alcance mínimo;
- bindings no secretos con TopicArn, QueueUrl, Region y settlement;
- backend S3 con KMS, versionado, recuperación y lockfile nativo;
- roots AWS separados para `dev`, `staging` y `prod`;
- pruebas Terraform sin credenciales ni recursos reales;
- ningún pipeline ni aprovisionamiento desde la API o los Workers.

## Fase 6

RabbitMQ combina el contrato backend con `RabbitMqPolicy` v1. Terraform crea un virtual host
dedicado, exchanges `topic`, una cola quorum por Consumer, bindings por routing y un límite de
entrega explícito. Cada cola decide si crea un DLX `direct` y una DLQ quorum dedicados.

Los usuarios de workload son preexistentes y distintos. Terraform administra permisos mínimos,
pero no crea usuarios porque el proveedor persistiría sus contraseñas en texto plano dentro del
estado. Las credenciales administrativas son variables efímeras y las connection strings llegan
desde el gestor de secretos. El backend HTTP remoto evita acoplar el estado a Azure o AWS.

Definition of Done:

- política RabbitMQ v1 validada por esquema, semántica y correspondencia exacta con backend;
- virtual host y nombres físicos aislados por producto y ambiente;
- exchanges `topic`, colas quorum durables y routing `#` o por tipo de evento;
- `delivery-limit` explícito por cola;
- DLX/DLQ opcionales por Consumer y dead-lettering `at-least-once` cuando se habilitan;
- permisos sin `configure`, publicación por exchange/evento y consumo solo de la cola fuente;
- ningún workload recibe acceso a una DLQ;
- bindings no secretos y requisitos de connection string separados;
- credenciales del proveedor omitidas de estado y planes mediante variables `ephemeral`;
- roots RabbitMQ separados para `dev`, `staging` y `prod`, con backend HTTP remoto y locking;
- pruebas de contrato y Terraform sin credenciales ni recursos reales;
- ningún pipeline ni aprovisionamiento desde la API o los Workers.

## Fase 7

La topología de desarrollo local vive en `local/`. El generador consume directamente el manifiesto
backend y, cuando se proporciona, la política DevOps del proveedor. Produce Docker Compose,
configuración declarativa y `LocalMessagingBindings` v1 por workload. El AppHost sigue orquestando
los procesos, pero solo valida e inyecta esos bindings.

AWS SNS/SQS y RabbitMQ respetan la decisión de DLQ/DLX de cada Consumer definida en la política;
sin política usan un perfil local explícito sin DLQ opcional. Azure conserva la DLQ intrínseca de
cada suscripción. Los artefactos, contraseñas y claves exclusivamente locales se ignoran en Git.

Definition of Done:

- topología local de Azure Service Bus, AWS SNS/SQS y RabbitMQ generada fuera del backend;
- contrato `LocalMessagingBindings` v1 validado y separado por workload;
- AppHost sin paquetes, assets ni llamadas de aprovisionamiento del broker;
- política DevOps opcional aplicada a nombres, reintentos y DLQ/DLX por cola;
- scripts deterministas con `-WhatIf`, espera de disponibilidad y parada acotada al producto;
- pruebas de generación para los tres proveedores y sus filtros;
- fixtures integrales aisladas documentadas como única excepción de topología desechable;
- ningún pipeline ni recurso cloud nuevo.

## Fase 8

La [operación de mensajería](operacion-mensajeria.md) declara una política por consumidor y ambiente.
Verifica contratos inmutables, genera entradas Terraform de alertas y permisos operativos separados,
y materializa destinos de recuperación desde outputs aplicados. Azure agrupa métricas por topic,
AWS observa cada cola y RabbitMQ entrega reglas por cola para Prometheus/Alertmanager.

La herramienta de DevOps inspecciona metadatos sin cuerpos ni cambios de entrega y reproduce lotes
acotados desde DLQ después de resolver el incidente. Conserva `HexagonMessageId`, tenant y cuerpo;
confirma la DLQ solo después de publicar. Un fallo entre ambas operaciones puede duplicar una
entrega, que absorbe el inbox. Las colas sin DLQ no tienen recuperación. El plazo de revisión de
cuarentena es independiente de la retención real de cada broker.

Definition of Done:

- política v1 validada por esquema y correspondencia exacta con topología y aplicación;
- alertas y permisos operativos explícitos, distintos de las identidades de los workloads;
- límites de métricas, retención y cuarentena documentados por proveedor;
- inspección pasiva y recuperación con plan, incidente, límite y ejecución deliberada;
- confirmación del destino antes del retiro del original; sobre e identidad del inbox conservados;
- DLQ RabbitMQ protegida contra el límite de entregas tras fallos operativos;
- logs saneados, pruebas unitarias y recuperación real en contenedores;
- ningún pipeline ni aplicación de recursos a ambientes compartidos.

## Fase 9

9A está integrada con la primera referencia Azure administrada. 9B incorpora [CI y artefactos](ci-y-artefactos.md)
por componente; requiere configurar las lecturas privadas documentadas para ejecutar todo el backend.
9C y 9D conservan el despliegue real y la promoción. No se ha aplicado infraestructura cloud.

La preparación de 9C incorpora [bootstrap declarativo de plataformas](bootstrap-plataformas.md):
contrato YAML, validación offline, plan de lectura y ejecución por etapas con planes revisados,
migración protegida y verificación GitHub Actions → Azure. El diagnóstico real de cada producto
debe finalizar en success antes de acreditar la preparación y continuar con Genesis.

La creación y retirada por ambiente adoptan [Genesis y Apocalypse](genesis-y-apocalypse.md)
([ADR 0012](adr/0012-genesis-y-apocalypse-por-ambiente.md)), inspirados en los workflows de
`movieops`. 9C implementará orquestación común para frontend/backend y dependencias, selector
`dev/staging/prod`, inventario aplicado y destrucción verificable sin borrar el bootstrap ni
plataforma compartida. 9D completará su adopción en ambientes persistentes.

El [motor de inventario](motor-ciclo-ambiente.md) ya implementa selección, dependencias, planes y
recuperación con un puerto obligatorio y tests con doble. El [adaptador Terraform/Azure](adaptador-ciclo-azure.md)
añade custodia remota del inventario/snapshot, lease/CAS y observación del proveedor. Tiene pruebas
locales/protocolo. Las [reservas efímeras y workflows](ciclo-efimero-azure.md) añaden identidad y
contenedor propios, etapas manuales revisadas y quiescencia; la entrega de aplicaciones y ejecución
integral real siguen pendientes.

La fase cubre frontend, backend e infraestructura. La
[ruta de entrega del producto completo](fase-9-entrega-producto.md) define su orden y Definition of
Done: 9A resuelve hosting y artefactos faltantes; 9B automatiza validaciones y construcción; 9C
despliega un ambiente efímero y comprueba navegador → API real; 9D promueve los mismos artefactos
entre ambientes con identidad federada, revisión del plan y aprobación por ambiente.

El frontend publica una SPA de producción y recibe `/runtime-config.json` desde el endpoint real
de API; se comprueban fallback, caché, ausencia de secretos y arranque. El backend verifica API,
Workers, migraciones y bindings reales. DevOps coordina los artefactos inmutables de ambas
aplicaciones, que conservan compilación y pruebas independientes. El contrato frontend existente
no equivale a tener su hosting implementado; ese trabajo y los bindings de hosting backend que
falten deben resolverse en 9A.

Kubernetes, Argo CD u otra plataforma de cómputo se decidirán al implementar hosting y despliegue;
la estructura de `movieops` sirve como referencia, no como decisión anticipada.

La [entrega verificable de 9C](entrega-aplicaciones-azure.md) conecta candidatos CI inmutables con
ACR, migraciones, permisos de base de datos y activación del backend. Publicación SPA y salud se
detallan a continuación. El E2E y la limpieza consentida se añaden en la guía de aceptación; falta evidencia cloud real.

La [publicación SPA y salud de hosting](publicacion-spa-y-salud.md) incorpora PublishWeb/VerifyServing
con el candidato original y evidencia de archivos, configuración pública y API/Workers. Ya están
implementados el E2E autenticado y la limpieza con consentimiento previo, según [aceptación integral](aceptacion-integral-azure.md). La ejecución Azure real sigue pendiente.
