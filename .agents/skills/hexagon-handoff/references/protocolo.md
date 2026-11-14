# Protocolo de cierre y relevo

## Fuentes y alcance

Usa las instrucciones vigentes, la conversación disponible y las fuentes del repositorio. Un
relevo anterior es evidencia histórica, no prueba del estado actual ni una autorización nueva.
Consulta los PR nombrados por ese relevo aunque no coincidan con la rama local; los demás agentes
pueden haberlos fusionado. Un fallo de acceso no significa que un recurso o PR no exista.

El índice central orienta; cada repositorio conserva sus reglas y rama base. No supongas que la
base siempre es main. Registra solo repositorios afectados o necesarios para contrastar pendientes,
sin recorrer todo el workspace ni atribuirte cambios de otras sesiones.

El procedimiento es reutilizable; los datos del cierre se guardan en el repositorio
privado o destino autorizado. Un modelo debe tener acceso a las fuentes para retomarlas. La skill
no puede recuperar una conversación perdida ni comprobar por sí sola toda la operación del sistema.

## Recoger hechos

El recolector opcional usa Python 3.10 o posterior y la biblioteca estándar. Solo ejecuta lecturas
de Git y, con `--github`, consultas de repositorio y PR de la rama actual usando GitHub CLI.
No hace fetch, checkout, commit, push, pruebas ni escrituras cloud. Las referencias locales pueden
estar desactualizadas. Para otros PR usa el conector o CLI disponible. Puede omitirse el recolector
si las herramientas del agente ya aportan los mismos hechos.

Recoge los siguientes datos, distinguiendo inspección estática, ejecución y observación remota:

- Objetivo y alcance solicitados; instrucciones que cambiaron el alcance durante la sesión.
- Repositorio, rama base, rama de trabajo, HEAD, PR y su HEAD remoto. Estado local, archivos
  modificados/no versionados y cambios conocidos de otros agentes, sin incluir su contenido.
- Qué cambió y qué falta. Distingue implementado, validado localmente, PR abierto, fusionado,
  publicado y operativo. Publicado y CI verde no equivalen a aceptación real del producto.
- Comprobaciones realmente ejecutadas: comando, resultado, revisión o alcance probado y evidencia
  duradera. Si no se ejecutaron, decirlo. El recolector no recoge ni acredita resultados de pruebas.
- Decisiones aprobadas y sus fuentes, autorizaciones específicas y límites. No generalizar una
  excepción de paquete, ambiente o publicación; si ya está documentada, enlazarla.
- Bloqueos, incertidumbres, pausas, intentos fallidos conservados y recuperación necesaria.

No incluir tokens, secretos, credenciales, estado Terraform, planes sensibles, cuerpos de mensajes,
datos reales de clientes ni transcripciones completas. Registra ubicación y motivo sin copiar
valores. Revisa incluso el resultado saneado del recolector antes de incorporarlo a Git.

## Actualizar sin pisar otra sesión

El destino de plataforma es el repositorio privado `hexagon-continuity`. Nunca escribas el relevo
en una plantilla ni en un producto: su contenido se copia a otros repositorios, incluidos públicos. En un producto, sigue el punto
de continuidad que definan sus instrucciones; conocimiento de negocio queda en business o Vision,
y las decisiones técnicas en sus ADR. No migres reglas a la skill para sustituir sus fuentes.

Usa rama/worktree propio para documentación si la rama actual contiene cambios ajenos o código
que no se pidió publicar. No hagas stash, reset, limpieza, cambios de rama, force push ni un
`git add .` indiscriminado para obtener un cierre limpio. Registra dónde quedó el trabajo local.

Un coordinador actualiza los archivos compartidos. Si otra sesión los está editando, entrega una
ficha separada y coordina su incorporación; no uses la última escritura como resolución automática.
Para fichas históricas usa una ruta nueva, por ejemplo
`relevos/20261112t153000z-cierre-a1b2c3.md` de `hexagon-continuity`; comprueba que no exista. Cada cierre
conserva la historia previa. Un reintento no duplica fichas o PR si ya hay uno que corresponde.

Actualiza únicamente lo necesario:

| Archivo | Cambio esperado |
| --- | --- |
| `estado.md` | Fotografía resumida, fecha, entregas observadas, cambios locales y enlace a la ficha. |
| `pendientes.md` | Cierres verificados, trabajo restante, dependencias y condición de cierre; conservar IDs. |
| `relevos/<fecha>-<id>.md` | Evidencia y contexto de esta sesión; no sustituye la ruta vigente. |
| `INICIO.md` | Enlaces o instrucciones de entrada que hayan cambiado. |
| AGENTS, guías y ADR | Solo políticas/procedimientos nuevos aprobados; no reescribir ADR aceptadas. |

Evita referencias circulares a la propia revisión del cierre: cita commits de código, observaciones
y PR concretos. El commit de documentación y su PR pueden indicarse en la entrega. No actualices
repetidamente el archivo para perseguir cada transición de CI: conserva hora y alcance observado,
y exige que el próximo agente contraste el estado remoto.

## Ficha mínima

Adapta la ficha al alcance sin inventar campos. Usa `No verificable` y la comprobación pendiente
cuando no haya acceso/evidencia. Una sesión cerrada no implica que su implementación esté terminada.

```markdown
# Cierre de trabajo

- Fecha y zona horaria:
- Objetivo y alcance:
- Sesión/agente responsable, si se conoce:
- Punto de entrada de continuidad:

## Hechos y evidencia

| Repositorio | Base / rama / HEAD | PR y estado observado | Comprobaciones / evidencia |
| --- | --- | --- | --- |

## Resultado

Qué se implementó, validó e integró; qué sigue abierto y qué no se verificó.

## Decisiones y restricciones

Fuentes vigentes, excepciones concretas, pausas y autorizaciones que debe conservar el relevo.

## Trabajo local y coordinación

Ramas/worktrees y archivos pendientes de commit/push, propietarios y áreas reservadas.

## Próximo paso

Tarea/ID, repositorio, dependencia, acción concreta y condición de cierre. Si falta autorización,
registrarlo sin ejecutarlo. No convertir el backlog completo en una orden.

## Orden para retomar

Lee el punto de entrada y esta ficha, verifica PR/HEAD actuales, lee los AGENTS de los repos
afectados y continúa el pendiente autorizado. Conserva pausas y deja comprobaciones y PR.
```

## Comprobar y entregar

Revisa coherencia entre estado, pendientes, fichas y PR. Confirma que los enlaces relativos
existen y que los remotos corresponden a la revisión descrita. Sigue los checks del repositorio;
no ejecutes una suite de producción o acceso cloud por el mero hecho de cerrar la sesión.

Donde las instrucciones exijan PR, publica únicamente los documentos propios del cierre, con su
evidencia y dependencias. Si el usuario pidió solo un cierre local, consérvalo local y dilo.
No marques fusionado por haber creado un PR ni cerrado un bloqueo por haber agotado el contexto.
