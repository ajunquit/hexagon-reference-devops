# ADR 0012: Genesis y Apocalypse por ambiente

- Estado: aceptada; implementación pendiente en 9C/9D
- Fecha: 2026-11-09

## Contexto

La fase 9B entrega CI y artefactos. 9C exige crear y retirar un ambiente efímero para comprobar el
producto completo. El dueño pide conservar la analogía de `movieops`: Genesis crea y Apocalypse
destruye el ambiente elegido. Los módulos actuales no equivalen a tener esos workflows.

Hexagon tiene estados distintos para hosting y mensajería. Algunos servicios, como Hexagon Auth y
el bootstrap del estado remoto, son externos al ciclo de vida del ambiente del producto.

## Decisión

La instancia DevOps ofrecerá `genesis.yml` y `apocalypse.yml` con selección explícita de `dev`,
`staging` o `prod`. Administrarán todos los recursos propios del producto/ambiente, incluidos
frontend, backend y dependencias declaradas. Genesis crea o reconcilia infraestructura y coordina
las etapas de entrega; no recompila artefactos. Apocalypse retira el conjunto según un inventario
persistente de lo aplicado y sus dependencias, con confirmación y revisión del plan de destrucción.

Terraform sigue siendo la única herramienta IaC. Se revisa y aplica el mismo plan por etapa/estado.
Creación, despliegue y destrucción comparten exclusión mutua por producto/ambiente, además de los
locks de cada estado. Las identidades cloud se federan con permisos acotados por ambiente.

La baja no incluye bootstrap/almacenamiento de estado, identidades operadoras, plataforma compartida
ni respaldos/artefactos retenidos fuera del ambiente. Los datos propios se eliminan únicamente tras
cumplir la política explícita de conservación y recuperación del ambiente.

## Consecuencias

La selección de ambiente no basta: se verifican producto, estados, ownership, identidad, planes y
protecciones antes de mutar. No se borra un resource group arbitrario ni se considera ausencia de
configuración como prueba de que no existan recursos. La retirada se comprueba por estado y recurso.

9C implementará el motor compartido, las entradas manuales y el ciclo efímero. 9D completará los
ambientes persistentes y la promoción. El diseño y la evidencia de `movieops` están en
[Genesis y Apocalypse](../genesis-y-apocalypse.md); esta ADR no declara esos workflows operativos.
