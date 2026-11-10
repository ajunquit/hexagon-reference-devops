# Genesis y Apocalypse: ciclo de vida de un ambiente

Estado: ciclo manual de infraestructura efímera implementado en 9C; aplicaciones y ejecución cloud
integral pendientes, con extensión a ambientes persistentes en 9D. El
[ADR 0012](adr/0012-genesis-y-apocalypse-por-ambiente.md) registra el diseño y el
[ADR 0017](adr/0017-reservas-efimeras-y-workflows-del-ciclo.md) su conexión por etapas.
La [guía del ciclo](ciclo-efimero-azure.md) contiene los comandos y alcance operativo actual.

El primer paso ya incorpora el [motor de inventario, planes y recuperación](motor-ciclo-ambiente.md),
según el [ADR 0015](adr/0015-motor-de-ciclo-de-ambiente-con-inventario.md). Sus pruebas usan un doble
del puerto. El adaptador Terraform/Azure, custodia remota y workflows ya están conectados para
instancias efímeras, con pruebas locales/protocolo; no acreditan ejecución cloud real.

## Referencia y estado actual

Se revisó `movieops` en el commit `ba199682b7366600f004c868d9f7b2f6575b641a`:

- [Genesis](https://github.com/ajunquit/movieops/blob/ba199682b7366600f004c868d9f7b2f6575b641a/.github/workflows/genesis.yml):
  ejecución manual, selector `dev/staging/production`, confirmación escrita, GitHub Environment,
  autenticación OIDC y plan guardado antes del apply.
- [Apocalypse](https://github.com/ajunquit/movieops/blob/ba199682b7366600f004c868d9f7b2f6575b641a/.github/workflows/apocalipsis.yml):
  selector equivalente, plan de destrucción y comprobación final de ausencia del resource group.
- [Runbook](https://github.com/ajunquit/movieops/blob/ba199682b7366600f004c868d9f7b2f6575b641a/docs/deployment.md):
  separa aprovisionamiento y despliegue; solo `dev` está implementado. `staging/production` tienen
  placeholders, por lo que el selector no acredita soporte operativo de esos ambientes.

Hexagon ya tiene módulos y roots por ambiente para hosting y mensajería, estado remoto separado y
CI. Ya incluye `genesis.yml`, `apocalypse.yml` y coordinación manual del adaptador de alta/baja. La limpieza
de contenedores locales no destruye un ambiente cloud. La ruta de fase 9 exigía retirar el ambiente
efímero; esta decisión concreta también la entrada manual de destrucción.

Se conserva la analogía de `movieops`, adaptada a Container Apps y Static Web Apps, contratos
inmutables y varios estados Terraform. No se adopta AKS por copiar la referencia.

## Experiencia de operación prevista

Cada instancia DevOps administra un producto. Ambos workflows ofrecerán un selector obligatorio
`environment` con `dev`, `staging` y `prod`; Hexagon conserva `prod` como nombre canónico de producción.
La configuración, el estado remoto y el GitHub Environment deben corresponder exactamente a esa
selección. No se deducen del nombre de rama.

| Entrada manual prevista | Alcance |
| --- | --- |
| `genesis.yml` — Genesis (Create Infrastructure) | Crear o reconciliar toda la infraestructura propia del producto en el ambiente seleccionado |
| `apocalypse.yml` — Apocalypse (Destroy Infrastructure) | Destruir esa infraestructura, incluidos frontend, backend y dependencias propias, y verificar su retirada |

Genesis no es exclusivo del backend. Prepara hosting web, API, Workers, datos, red, identidades,
registro, observabilidad y mensajería que declare el producto. El despliegue de artefactos y las
migraciones son etapas explícitas coordinadas después de aprovisionar; crear infraestructura no
acredita por sí solo una aplicación operativa. Se reutiliza esa coordinación para entregar el
ambiente completo sin recompilar. Un producto solo backend omite web.

Ambos workflows requieren confirmación escrita que identifique operación, producto y ambiente.
Genesis toma el descriptor y la release aprobados por referencias inmutables. Apocalypse usa el
inventario realmente aplicado: no exige que las aplicaciones o un artefacto de CI todavía estén
disponibles para poder retirar recursos. No admite rutas, comandos o selectores de proveedor libres
como sustituto de la configuración revisada del producto.

## Propiedad y alcance de «todo»

| Recurso | Tratamiento de Apocalypse |
| --- | --- |
| Hosting frontend, API, Workers y jobs propios | Retirar junto con el ambiente |
| PostgreSQL, registro, red y observabilidad propios | Retirar tras cumplir la política de conservación de datos/evidencia |
| Broker dedicado o topología/permisos del producto en un broker externo | Retirar solo los recursos y permisos administrados por los estados del ambiente |
| Hexagon Auth, DNS o servicios de plataforma compartidos | Conservar; solo retirar bindings propios si están administrados explícitamente |
| Gestor de secretos preexistente o compartido | Conservar; eliminar únicamente elementos propios cuya gestión y baja estén declaradas |
| Almacenamiento de estado Terraform y bootstrap | Conservar, junto con la identidad necesaria para operar y recuperar el ambiente |
| Grupos de recursos de ambiente administrados por bootstrap | Conservar como límites persistentes de RBAC; retirar solo los recursos interiores de los estados de workloads |
| Backups, evidencia y artefactos duraderos retenidos | Conservar fuera del ambiente según su política; una baja no los elimina implícitamente |

No se promete que Terraform elimine recursos ajenos a su estado, repositorios fuente ni servicios
externos. Para una plataforma completa no pueden quedar recursos propios fuera de un inventario:
si aún no existe su módulo, se declara la dependencia o el trabajo pendiente antes de ejecutar.
La cobertura depende de lo implementado, no de que aparezca una opción en el selector.

## Orquestación de creación

1. Validar producto/ambiente, contratos, políticas, procedencia de release, permisos y presupuesto.
   Comprobar bootstrap remoto e identidad de despliegue; no crear el backend del estado dentro de
   la misma operación que depende de él.
2. Crear infraestructura base de hosting con aplicaciones y jobs desactivados. Conservar inventario
   de roots, backend/key de cada estado, commit IaC, versiones, inputs protegidos e identificadores
   obtenidos, incluso si la ejecución falla a mitad.
3. Importar los artefactos verificados conservando digests. Crear la topología y RBAC del proveedor
   seleccionado usando las identidades de hosting; resolver bindings e identidad pública de Auth.
4. Activar y ejecutar migraciones y bootstrap de permisos, esperando resultados satisfactorios.
5. Activar API/Workers, publicar la SPA con su overlay público y verificar el recorrido integral.

Cada etapa genera y aplica su plan revisado con los outputs de las etapas anteriores. No se
reutiliza un plan obsoleto después de cambiar su estado o inputs. El detalle de activación sigue
la [referencia de hosting](hosting-azure.md#orden-de-activación).

## Orquestación de destrucción

1. Recuperar el inventario aplicado y comprobar identidad exacta del producto/ambiente, configuración
   IaC compatible y acceso a todos sus estados. Un root ausente o estado inaccesible no significa
   que no haya nada que destruir. Si ya fue retirado, demostrarlo con inventario, estado y proveedor.
2. Detener entradas de tráfico, nuevas escrituras y trabajos. Esperar o resolver mensajes y efectos
   pendientes según la política; conservar backups y evidencia fuera de los recursos que se borran.
   Destruir PostgreSQL o una cola también puede destruir datos; en producción se exige la política
   de recuperación revisada y evidencia de los respaldos requeridos antes de continuar.
3. Planificar y retirar la topología, permisos y alertas propios de mensajería antes de eliminar las
   identidades o el hosting que los referencian. Eliminar después hosting web/backend, jobs y sus
   dependencias. Cada root resuelve sus dependencias internas; el orquestador resuelve las que
   atraviesan estados. El orden se deriva del inventario, no de un bucle alfabético de carpetas.
4. Verificar todos los estados implicados y consultar el proveedor con espera acotada hasta confirmar
   ausencia de los recursos retirados. No basta comprobar un solo resource group: hosting y broker
   pueden estar separados. Registrar los recursos conservados de forma intencional.
5. Si queda algo pendiente o no puede verificarse, fallar con evidencia y permitir reanudar usando
   el mismo inventario. No borrar estados, sus locks ni el inventario para aparentar éxito.

Los planes de baja se generan con `terraform plan -destroy -out=<plan>` y se aplica exactamente el
archivo revisado mediante `terraform apply <plan>`. Los planes contienen información sensible y
requieren acceso y retención protegidos; no se publican completos en PR ni como evidencia pública.
[Referencia de planificación Terraform](https://developer.hashicorp.com/terraform/cli/commands/plan).

## Controles de ejecución

- Entradas manuales desde código confiable en `main`, acciones fijadas por SHA, validación de inputs
  y paso de valores a través de variables de entorno/argumentos seguros, sin interpolarlos como shell.
- Plan y ejecución separados, con aprobación posterior a disponer del plan. Confirmar un texto antes
  del plan no sustituye esa revisión. Producción exige autorización de destrucción y aprobación por
  ambiente; las protecciones deben comprobarse al configurar el repositorio.
- Identidad OIDC por ambiente y permisos mínimos para cada operación. Las identidades de ejecución
  de API/Workers no reciben permisos de aprovisionamiento o destrucción. La GitHub App de lectura
  de fuentes es independiente de esta identidad cloud.
- Una misma exclusión mutua por producto/ambiente para creación, despliegue y destrucción, con
  `cancel-in-progress: false` en operaciones cloud y locking Terraform por estado. Crear y destruir
  no pueden ejecutarse a la vez sobre el mismo ambiente.
- No retirar `prevent_destroy`, locks cloud ni otras protecciones automáticamente para forzar una
  baja. Una política que impida destruir debe producir un bloqueo explícito y revisable.

## Incorporación a 9C y 9D

9C implementará primero scripts y pruebas de inventario, selección, orden, planes, fallo parcial y
verificación de baja; después las entradas manuales Genesis/Apocalypse y la composición efímera
Azure. La prueba efímera usará la misma lógica de retirada, ejecutada al finalizar incluso tras
fallos, con reconciliación posterior si un runner desaparece o se cancela. Su identidad y estado
deben aislarse de un `dev` persistente: seleccionar `dev` no autoriza borrar otro entorno existente.
La instancia efímera tendrá un identificador derivado de su ejecución, presente en nombres,
inventario y keys de estado. Su limpieza exigirá esa identidad exacta; no podrá caer por defecto
en las keys del ambiente persistente si falta el identificador.

El selector ofrecerá los tres ambientes, pero fallará antes de cualquier mutación si faltan
configuración o protecciones de uno. 9D completará adopción en ambientes persistentes y promoción
de las mismas releases, sin duplicar los motores de creación/destrucción.

La implementación deberá acreditar creación → verificación → destrucción, conservación del
bootstrap/plataforma y recuperación tras fallo parcial antes de anunciar el ciclo como operativo.
Documentar estos workflows no los implementa ni autoriza ejecutar una destrucción real.
