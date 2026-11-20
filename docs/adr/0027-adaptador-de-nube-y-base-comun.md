# ADR 0027: Un adaptador de nube por plantilla sobre una base común

- Estado: aceptada
- Fecha: 2026-11-20
- Decisión del dueño sobre la separación por nube, el 2026-11-19
  ([ADR 0043 de plataforma](https://github.com/ajunquit/hexagon-template-ng/blob/main/docs/adr/0043-una-plantilla-devops-por-nube.md)).
- Sustituye parcialmente: [ADR 0004](0004-una-plantilla-devops-con-monolito-modular-inicial.md) y
  [ADR 0022](0022-un-devops-para-monolitos-simples-y-modulares.md), en la regla "una sola plantilla
  DevOps". Se conserva que no hay variantes por arquitectura (mx, ml, ms).

## Contexto

Esta plantilla contiene AWS y Azure. Sus puntos de entrada decidían la nube con `if ($aws)`, y
módulos con nombre de una nube guardaban piezas que usaban las dos. Para separarla en
`hexagon-core-devops`, `hexagon-template-devops-aws` y `hexagon-template-devops-az`, lo común no
puede saber de qué nube es.

## Decisión

- **Cada nube aporta un adaptador** `<Nube>CloudAdapter.psm1` con el contrato de
  [la separación por nube](../separacion-por-nube.md#el-contrato-del-adaptador-de-nube):
  - reconoce su destino;
  - abre y cierra el ciclo con su identidad y su lease;
  - lee el journal;
  - nombra su punto de entrada nativo;
  - ejecuta las etapas de entrega que existen en ella.
- **La base elige el adaptador por el destino del inventario** y llama a sus funciones dentro del
  módulo. Si ningún adaptador reconoce el destino, falla (`lifecycle.cloud.targetUnsupported`).
- **Las herramientas de línea de comandos y el host web** de cada nube siguen la misma idea:
  `*LifecycleTools.psm1` y `*WebHost.psm1`, descubiertos por nombre.
- **Los módulos que se descubren no exportan nada**, para que puedan convivir los de varias nubes
  hasta que la plantilla se divida.
- **El adaptador orquesta; no abstrae la infraestructura.** Los módulos Terraform, los contratos de
  hosting y la mensajería de cada nube siguen separados y con su propia semántica.
- **Lo común no nombra servicios de una nube ni importa scripts de una, y una nube no importa la
  otra.** Lo comprueba `scripts/cloud_classification.py`.

## Consecuencias

- Los puntos de entrada comunes funcionan igual con una o con varias nubes. En la fase 3 cada
  plantilla lleva solo su adaptador.
- Una nube nueva (GCP) añade su adaptador, sus herramientas, su host web, sus roots y sus workflows,
  sin tocar la base.
- `lifecycle.azure.trustedWorkflowRequired` pasa a ser `lifecycle.trustedWorkflowRequired`, porque
  lo lanza la base.
- **Queda pendiente** mover al adaptador las reglas del plan y las raíces del snapshot, que siguen
  dentro del motor.
