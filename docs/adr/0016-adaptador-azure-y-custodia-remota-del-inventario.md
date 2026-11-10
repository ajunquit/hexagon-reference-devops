# ADR 0016: adaptador Azure y custodia remota del inventario

- Estado: aceptada; implementación local/protocolo, pendiente de verificación cloud
- Fecha: 2026-11-10
- Amplía: [ADR 0015](0015-motor-de-ciclo-de-ambiente-con-inventario.md)

## Contexto

El motor define revisión, checkpoints y observaciones, pero necesita ejecutarlas en servicios
reales. La recuperación no puede depender del workspace perdido ni del CI de las aplicaciones.
Hosting y mensajería también necesitan inputs por etapas: los principal IDs todavía no existen
al preparar la infraestructura inicial.

## Decisión

Un adaptador explícito Terraform/Azure implementa el puerto. Conserva snapshot, inventario, planes
y evidencia en Blob dentro del prefijo de producto/ambiente/instancia. Lease infinito del control,
revisión consecutiva y CAS por ETag serializan clientes cooperativos; Terraform mantiene su lock.
La escritura solo se acredita después de leer y contrastar los bytes remotos.

El snapshot contiene roots, módulos, locks e inputs públicos/referencias; fija versión Terraform y
hashes. El código proviene de objetos Git del commit registrado, ancestro del main confiable. La
recuperación vuelve a contrastar esos bytes con Git; checksums de Blob no autorizan código. No se
aceptan rutas/comandos libres del inventario. La extracción es acotada y el workspace privado.

La identidad CLI debe coincidir con tenant/suscripción/client ID. ARM solo se consulta para
observación; Terraform crea/retira workloads. Los grupos y dos roles retenidos del bootstrap se
verifican y conservan. El adaptador no aprovisiona la identidad efímera ni rompe locks automáticamente.
Apply solo se conecta a entradas manuales Genesis/Apocalypse de main, protegidas mediante OIDC y
Environments en la integración posterior. No se habilita apply local contra ambientes compartidos.

La observación contrasta estado remoto, ETag, lineage/serial, grupos y sondas de IDs históricos;
Create exige convergencia del plan y Destroy ausencia verificable. Acceso denegado nunca es ausencia.
La baja DeleteEphemeral observa quiescencia; no la fuerza. BackupRequired queda bloqueada hasta
tener verificación de respaldos auténticos en 9D.

UpdateInputs crea un snapshot nuevo del mismo código, conserva recursos/historial y exige un plan
nuevo. Solo cambia el root elegido. Esto permite enlazar identidades de hosting y habilitar etapas
posteriores sin editar el inventario a mano ni reutilizar aprobaciones.

## Consecuencias

La retirada deja de depender de artefactos de aplicación, pero conserva la dependencia deliberada
de Git DevOps confiable, Terraform y proveedores fijados. Un lease abandonado necesita recuperación
operativa revisada. Los futuros workflows deben compartir el protocolo de exclusión y custodiar
Blob/RBAC; un administrador que ignore el protocolo queda fuera de esa exclusión cooperativa.

Las pruebas usan Git y plan Terraform reales, y simulación explícita de HTTP/ejecución cloud.
No equivalen a Azure verificado ni cierran 9C. Identidad efímera, workflows, aplicaciones y recorrido
integral siguen pendientes, según la [guía del adaptador](../adaptador-ciclo-azure.md).
