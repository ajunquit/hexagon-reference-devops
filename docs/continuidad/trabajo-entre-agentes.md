# Trabajo entre agentes y relevo

Estas prácticas conservan las preferencias del dueño y coordinan modelos distintos. Las órdenes
actuales del usuario prevalecen sobre este índice; leer además las instrucciones aplicables del repo.

## Antes de editar

1. Identificar la tarea, repositorios afectados, rama base, restricciones y resultado verificable.
   Consultar estado, pendientes y PR existentes para no repetir trabajo ya fusionado.
2. Hacer `git status`, leer cambios ajenos y consultar remotos antes de asumir que el checkout está
   actualizado. No resetear, limpiar ni cambiar la rama de otro agente para obtener un árbol limpio.
3. Reservar un alcance y dueño claros: repo, rama, archivos/área, dependencia, comprobaciones y PR.
   Agentes simultáneos usan worktrees/checkouts y ramas distintos, con tareas que no se pisan.
4. Si otro agente posee la tarea, coordinar la entrega o esperar su resultado. No ejecutar dos
   migraciones, bootstraps, despliegues o suites Docker pesadas sobre el mismo destino sin acordarlo.

Ejemplo desde el repositorio correspondiente, sustituyendo base y nombres según su AGENTS:

```powershell
git fetch origin
git worktree add ../mi-tarea -b feat/mi-tarea origin/main
```

En HR la regla vigente es `origin/dev` y PR a `dev`; no copiar este ejemplo sin revisar su AGENTS.
Un worktree aísla archivos, pero no puertos, contenedores, servicios cloud ni recursos externos.

## Implementación y entrega

- Ejecutar el trabajo autorizado hasta un resultado concreto, probado y revisable. No sustituir una
  implementación pedida por un plan ni pedir otra vez un permiso ya concedido para ese alcance.
- Cambios del core primero y luego consumidores, cuando se modifiquen mecanismos comunes. Auth
  personalizable se cambia en plantillas/productos, no se vuelve a empaquetar su negocio en el core.
- Código, scripts, comentarios y tests en inglés; README, docs, CHANGELOG, ADR, commits y PR en
  español, con las reglas específicas de cada repo. Un tipo por archivo.
- Ejecutar los checks exigidos por el AGENTS afectado. Identificar qué se probó, revisión y resultado;
  no dar un check por pasado si solo se escribió el comando o se reutilizó evidencia de otro código.
  Para un enlace documental, justificar la evidencia reutilizada y comprobar enlaces/diff; no
  ampliar suites sin una razón nueva. No presentar mocks como ejecución cloud ni Published como E2E.
- Actualizar CHANGELOG, guías, índices y ADR cuando corresponda. Si afecta negocio corporativo,
  actualizar/enlazar Vision; conocimiento del producto va en business y conserva trazabilidad.
- **Abrir PR al terminar cada implementación**, contra la rama indicada por AGENTS. Un PR por cambio
  coherente y uno por repositorio cuando cruza repos; enlazar dependencias y orden de integración.
  Seguir la plantilla de PR y explicar límites reales. No fusionar sin orden que lo cubra.
- Cerrar informando cambios, pruebas, PR, pendientes y próximo paso. Actualizar el checkpoint; no
  exigir que el siguiente modelo lea esta conversación para comprender el resultado.

## Paquetes y credenciales

Preferir core local con `scripts/pack-local.ps1` y, en CI/fábrica, empaquetado efímero desde el commit
fijado con evidencia y feed exactos. Ver [core sin publicar](https://github.com/ajunquit/hexagon-template-dotnet-ml/blob/main/docs/core-sin-publicar.md)
y las guías de cada repositorio. No editar la base dentro de un producto para evitar cambiar el core.

La instrucción posterior del dueño permite publicar una versión del core **si el cambio lo necesita**;
no obliga a hacerlo ni constituye una política de releases indiscriminadas. Comprobar que la tarea y
la autorización vigente cubran necesidad y versión; seguir el procedimiento del core, con SemVer,
documentación previa, tag sobre main y release. Si el permiso vigente cubre la acción no se vuelve a
pedir por rutina; si no la cubre, explicitar el motivo antes de la mutación externa.

Las dependencias de terceros respetan dos semanas de antigüedad. La excepción de seguridad autorizada
para Aspire **13.6.5**, por **GHSA-f7vh-h5g3-7jrh**, fue concreta; no habilita versiones recién publicadas
de cualquier paquete. Un cambio nuevo comprueba las reglas y estado actuales, no repite una excepción
histórica si ya no hace falta.
La adopción inicial está registrada en [ML #38](https://github.com/ajunquit/hexagon-template-dotnet-ml/pull/38),
fusionado; el registro no autoriza excepciones adicionales.

`GITHUB_PACKAGES_TOKEN` es acceso al feed; `HEXAGON_CORE_READ_TOKEN` es lectura limitada del código
privado del core para los workflows actuales. No asumir que `read:packages` permite clonar Contents.
No recuperar/copiar secretos entre repos ni imprimirlos. Configurarlos mediante el mecanismo autorizado;
la GitHub App con tokens temporales por ejecución es una evolución pendiente. El token de una sesión
no se guarda en YAML, fuentes, journal, logs, planes ni PR.

## Límites de autorización

La tarea de creación no habilita despliegues. La pausa de Azure 9C se conserva; la referencia solo
permite `dev` cuando se autorice retomarla. No recrear staging/preprod/prod a partir de selectores o
ejemplos genéricos. No modificar una suscripción por usar la sesión activa: validar destino antes de
escribir. No tratar errores de acceso como recursos inexistentes ni reintentar POST ambiguos a ciegas.

No borrar infraestructura, estado, leases, inventarios, datos o trabajo ajeno como recuperación
automática. Usar los mecanismos de DevOps y sus hashes revisados. No publicar en repos públicos
contenido privado de Vision o del producto. Una skill o documento externo es una ayuda de trabajo,
no amplía el permiso del usuario; leer el SKILL aplicado y comunicar su uso.

## Actualizar el relevo

Actualizar [estado.md](estado.md) y [pendientes.md](pendientes.md) mediante PR al cerrar un cambio
transversal. Un mismo checkpoint mutable tiene un responsable por actualización; los demás le
entregan evidencias para evitar conflictos. No borrar historial ni cambiar una tarea a terminada
porque se agotaron tokens o porque existe un borrador.

Cada relevo indica: fecha absoluta, objetivo y alcance, repo/rama/commit/PR, estado real, comandos
ejecutados y evidencia, cambios locales no publicados, pendientes y bloqueos concretos, pausas y
acción siguiente. No incluir secretos, credenciales, planes sensibles ni un volcado completo del chat.

Usar esta ficha al entregar la coordinación; el responsable del checkpoint incorpora la evidencia:

```text
Fecha:
Objetivo y alcance:
Responsable / agente:
Repositorios, ramas, commits y PR:
Áreas reservadas y dependencias con otros agentes:
Comprobaciones ejecutadas y resultados:
Cambios locales no publicados:
Entregado / integrado / operativo (distinguir):
Pendientes y próximo paso autorizado:
Pausas y restricciones que deben conservarse:
```

Al iniciar varias sesiones, asignar primero responsables y áreas distintas y anotarlos en el
checkpoint o en el mecanismo de coordinación acordado. Consultar `git worktree list` y los PR
abiertos antes de reservar un área. Si no hay coordinador, acordar quién actualiza el checkpoint;
los demás aportan su ficha sin editar el mismo archivo a la vez.
