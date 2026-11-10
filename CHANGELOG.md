# Registro de cambios

Los cambios relevantes de la plantilla se documentan en este archivo.

## Sin publicar

### Añadido

- Aceptación autenticada con navegador, perfil lógico por componente, semilla aislada de tenants
  y job Terraform opcional. PrepareAcceptance genera consentimiento de recursos exactos;
  Acceptance prueba UI/OIDC/API/Worker/aislamiento y retira la instancia por el motor, también
  tras fallos de prueba. Evidencia previa a borrar, límite dev/staging y recuperación con
  Apocalypse. ADR 0020, Chromium y pruebas de protocolo; ejecución Azure real pendiente.

- Publicación del candidato SPA sin recompilar, con overlay público y marcador determinista.
  Etapas PublishWeb/VerifyServing, cliente oficial fijado por build/checksum y token de sitio en
  memoria. Verificación HTTP de todos los archivos, MIME/caché/fallback y salud ARM de API/Workers,
  con evidencia durable. Incluye ADR 0019 y pruebas; E2E autenticado, limpieza automática y
  ejecución Azure real continúan pendientes.

- Entrega de candidatos 9B por run/intento/artifact ID y hash, con procedencia CI/main, OCI/SPA y
  manifiestos verificados. Copia OCI a ACR sin reconstruir, journal Blob con lease/CAS y jobs de
  migraciones/acceso reconciliables por intento. Workflow Application Delivery con planes separados
  para mantenimiento y activación del backend. Incluye ADR 0018 y pruebas HTTP/archivos locales;
  la publicación SPA, salud, recorrido integral, limpieza automática y ejecución cloud siguen pendientes.

- Genesis/Apocalypse manuales por ambiente/instancia/root, con Prepare/Apply separados, planes
  privados por hash, OIDC, protecciones, concurrencia común y recuperación desde inventario remoto.
  Reserva Terraform efímera con identidad/grupos/contenedor propios y CLI del operador para plan,
  aplicación y configuración GitHub. Enlace automático de principal IDs de hosting y quiescencia
  explícita de recursos inventariados. Incluye ADR 0017 y pruebas de protocolo/Terraform; todavía
  no ejecuta una cuenta real ni incorpora entrega de aplicaciones, limpieza integral automática o 9D.
  Las asignaciones RBAC de hosting, mensajería y operación declaran ServicePrincipal explícitamente
  para que la delegación condicionada por PrincipalType pueda autorizar su creación.

- Adaptador Terraform/Azure del motor de ambiente: snapshots contrastados con Git, custodia Blob
  con lease y CAS, planes inmutables, recuperación independiente de artefactos de aplicación y
  observación ARM/estado. Actualización de inputs por root conserva historial e invalida aprobación.
  Incluye CLI, ADR 0016 y pruebas locales/protocolo. No ejecuta recursos cloud ni incorpora aún
  workflows/identidad efímera; BackupRequired permanece bloqueada hasta un verificador real en 9D.

- Motor de ciclo de ambiente previo a Genesis/Apocalypse: EnvironmentInventory v1, selección exacta,
  estados/key de instancia, grafo de alta/baja, planes ligados a hashes/revisión y checkpoints antes
  de ejecutar. Conserva IDs y fallos parciales, exige observación para verificar retirada y respaldo
  en producción. Incluye CLI local de inventario, ADR 0015 y pruebas con un doble del puerto.
  No incorpora todavía adaptador cloud, custodia remota ni workflows; 9C permanece abierta.

- Ejecución del bootstrap GitHub Actions/Azure: Prepare/Apply por etapa con hashes y vigencia,
  migración con locking y recuperación, reconciliación de Environments/protecciones/variables y
  Verify con audiencia/subject/RBAC exactos y diagnóstico manual real. Terraform crea una identidad
  y un contenedor de estado por ambiente, permisos limitados a sus grupos y delegación condicionada.
  Incluye ADR 0014, pruebas de segunda ejecución, fallos parciales y rechazo de checks cancelados.
  La suite usa dobles/mocks; todavía no se ha aprovisionado una cuenta real ni cerrado 9C.

- Primer bloque de bootstrap de plataformas GitHub Actions/Azure: YAML estricto, validación offline,
  plan de lectura y resultado JSON versionado con estados y hashes. Rechaza identidad/grupos
  compartidos, target incorrecto y valores desconocidos sin revelar el YAML rechazado. Incluye
  pruebas sin credenciales y ADR 0013; no implementa Apply ni ejecuta cambios cloud.

- Diseño de Genesis/Apocalypse por ambiente y ADR 0012, tomando `movieops` como referencia:
  creación/destrucción del conjunto frontend/backend y dependencias propias, inventario de estados,
  revisión de planes y conservación de bootstrap/plataforma. Implementación prevista en 9C/9D;
  no añade workflows ni ejecuta operaciones cloud.

- Ruta documentada de evolución del acceso privado desde el PAT fine-grained separado de 9B a
  una GitHub App con tokens temporales por job para varios productos. Incluye permisos mínimos,
  custodia de la clave y adopción verificada antes de retirar el PAT; sin cambios de workflows.

- Fase 9B: GitHub Actions para validación de contratos/fuentes, Terraform, integración de brokers
  y PostgreSQL; build del bootstrap como OCI verificado. Sin apply ni identidades cloud.
- ComponentBuild v1 y validador de identidad, contratos, checksums, blobs OCI y bundles estáticos;
  pruebas negativas de alteración/rutas/bindings. Política de candidatos solo desde main y ADR 0011.
- Validación de TTL y ventana de duplicados del emulador Azure antes de generar topología; política
  de prueba explícita dentro de sus límites y limpieza obligatoria en las pruebas de ciclo local.
- Hook de inicialización LocalStack marcado como ejecutable en Linux/macOS, verificado por CI;
  la disponibilidad del contenedor ya no oculta una topología sin crear por permisos del archivo.
- Inspección de archivos ocultos en el guardrail de repositorio también en Linux.
- Checksums de proveedores Terraform para Windows y Linux en los 18 roots, conservando sus
  versiones y la verificación readonly de dependencias.

- Fase 9A: referencia Terraform Azure con Container Apps, Static Web Apps, PostgreSQL privado,
  ACR, identidades por workload y jobs separados para migración/bootstrap, sin aplicar recursos.
- Contratos `AzureHostingPolicy` y `ApplicationRelease` v1, exportación de inputs desde fuentes
  inmutables y overlay público de SPA con OIDC, fallback y reglas de caché. Hosting backend opcional
  en el generador de descriptores; validaciones y pruebas locales/mocks, sin pipelines nuevos.

- Ruta de fase 9 para el producto completo: frontend, backend e infraestructura, con prerrequisitos
  de hosting, CI de aplicaciones, ambiente efímero de extremo a extremo y promoción de artefactos
  inmutables. Define verificación de SPA, configuración pública, API/Workers e integración real.
  Este ajuste documenta el alcance; no implementa hosting, pipelines ni despliegues.
- Fase 8: `MessagingOperationsPolicy` v1 por consumidor y ambiente, con umbrales, plazo de revisión,
  identidades operativas separadas y recuperación habilitada explícitamente con lote y pausa.
- Materialización desde contratos inmutables y outputs Terraform: alertas Azure Monitor por topic,
  CloudWatch por cola y reglas Prometheus por cola RabbitMQ, junto a permisos operativos mínimos.
- Herramienta .NET independiente del backend para inspección pasiva y reproducción desde DLQ:
  plan por defecto, ejecución explícita, conservación del sobre y ack solo tras publicar.
- Política de cuarentena RabbitMQ sin límite de entrega para evitar pérdidas tras fallos del operador,
  aplicable a DLQ existentes sin redeclararlas y presente también en la topología local.
- Guía operativa y ADR 0009; pruebas de retención, permisos, exportación y recuperación contra Azure
  Service Bus, LocalStack y RabbitMQ efímeros. Sin pipelines ni aplicación a ambientes compartidos.

- Fase 7 de mensajería local: generación determinista de Docker Compose y topología para Azure
  Service Bus, AWS SNS/SQS y RabbitMQ desde el manifiesto backend y la política DevOps opcional.
- Contrato `LocalMessagingBindings` v1 por workload, entregado al AppHost mediante un archivo local
  ignorado por Git.
- Scripts para generar, iniciar, esperar y detener la mensajería local, con selección de DLQ/DLX por
  cola al aplicar las políticas de AWS o RabbitMQ.
- Fase 6 de RabbitMQ: contrato `RabbitMqPolicy` v1, materialización desde el manifiesto backend
  inmutable y roots RabbitMQ independientes para `dev`, `staging` y `prod`.
- Módulo Terraform con virtual host dedicado, exchanges, colas quorum, bindings, límite de entrega,
  DLX/DLQ opcional por cola y dead-lettering `at-least-once` cuando se habilita.
- Permisos mínimos para usuarios preexistentes por workload, claves de connection string para el
  gestor de secretos y credenciales administrativas `sensitive` y `ephemeral`.
- Backend HTTP remoto para el estado de RabbitMQ, desacoplado de Azure y AWS y con locking
  configurado externamente.
- Fase 5 de AWS SNS/SQS: contrato `AwsSnsSqsPolicy` v1, materialización desde el manifiesto backend
  inmutable y roots AWS independientes para `dev`, `staging` y `prod`.
- Módulo Terraform con topics y colas estándar cifrados, Raw Message Delivery, filtros por
  `EventType`, policies restringidas, permisos IAM mínimos y redrive/DLQ opcional por cada cola.
- Bootstrap S3 con KMS, versionado, Public Access Block y lockfile nativo de Terraform.
- Fase 4 de Azure Service Bus: contrato `AzureServiceBusPolicy` v1 por ambiente, materialización
  determinista desde el manifiesto backend fijado por commit y SHA-256, y roots Terraform separados
  para `dev`, `staging` y `prod`.
- Módulo Terraform de Azure Service Bus con namespace sin autenticación local, topics,
  suscripciones, filtros explícitos por `Subject`, TTL, entregas máximas, DLQ incorporada y RBAC
  Sender/Receiver en el menor alcance.
- Bindings no secretos por workload y pruebas de contratos/Terraform sin crear recursos reales.
- Bootstrap del backend remoto Azure con autenticación por identidad, versionado, recuperación,
  protección contra eliminación y keys de estado separadas por ambiente.
- Estructura inicial de `hexagon-template-devops`, preparada para una instancia independiente por
  producto y ambientes `dev`, `staging` y `prod`.
- Una única plantilla DevOps para todo el ciclo de vida del producto: monolito modular inicial y
  extracción posterior de servicios solo ante una necesidad demostrada, sin variantes `-ml` o
  `-ms` ni migración del estado a otro repositorio.
- Contrato `ProductEnvironment` v1 para fijar repositorio, commit y `SHA-256` de los manifiestos de
  frontend y backend aplicados en cada ambiente.
- Scripts para generar, validar y verificar descriptores contra las fuentes inmutables en GitHub.
- Decisión no negociable de usar Terraform y límites separados para Azure Service Bus, AWS SNS/SQS
  y RabbitMQ.

### Corregido

- Las funciones públicas que escriben en el motor de ambiente reconocen WhatIf: omiten locks,
  escrituras y llamadas al puerto de ejecución. La CLI evita una segunda confirmación al crear
  el inventario después de haber aprobado esa misma operación.

### Al actualizar un producto

- En DevOps, integra los módulos Azure junto con el ciclo: sus roles de workloads y operadores
  declaran ServicePrincipal para la delegación condicionada. Los IDs operativos deben ser de
  identidades de servicio separadas, no usuarios humanos; revisa el plan antes de aplicar.

- Los grupos Azure de hosting/mensajería pasan a ser límites persistentes propiedad del bootstrap.
  Los workloads los consultan y Apocalypse los conservará. Instalaciones existentes requieren una
  transferencia revisada de ownership entre estados, con backups y planes sin recreación; no se
  adopta ni migra automáticamente infraestructura existente. Cada ambiente usa ahora un contenedor
  separado; no apuntes al contenedor de bootstrap con la identidad de despliegue.

### No incluido todavía

- Clúster RabbitMQ, Kubernetes, ejecución cloud del producto, Genesis/Apocalypse y promoción
  entre ambientes. La observabilidad de mensajería, recuperación DLQ y CI ya tienen mecanismos;
  su operación real requiere los bindings y recursos del producto.
