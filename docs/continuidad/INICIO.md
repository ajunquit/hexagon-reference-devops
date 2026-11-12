# Continuidad de Hexagon: empezar aquí

Este es el punto de entrada para una persona o agente que continúa el trabajo sin recibir el chat
anterior. Es un **índice privado de coordinación**, no una especificación que sustituya las fuentes
de cada repositorio ni una autorización para desplegar, publicar o fusionar.

## Orden para continuar

1. Leer [el mapa y las decisiones vigentes](mapa-y-decisiones.md).
2. Leer [el estado y la evidencia](estado.md), comprobar los PR en GitHub y distinguir cambios
   fusionados, abiertos, código validado y ejecución cloud. El estado es una fotografía fechada.
3. Elegir un único trabajo de [la ruta pendiente](pendientes.md) que esté cubierto por la orden del
   usuario. Un backlog no concede autorización para ejecutar todo lo enumerado.
4. Leer `AGENTS.md`, README, ADR y guías del repositorio afectado en su rama base real. Comprobar
   también las instrucciones de sus directorios padre. **No asumir que la base siempre es main**.
5. Seguir [el protocolo de colaboración y relevo](trabajo-entre-agentes.md): reservar alcance,
   trabajar en un checkout aislado, comprobar y abrir PR. Actualizar la evidencia antes de terminar.

La fábrica de productos y este relevo ya están integrados. La entrega en revisión es F-01, la
sincronización asistida de plantillas (Factory #2 y sus PR de documentación); ver el estado.
**La validación Azure 9C está pausada**. Leer su guía o ver un selector `staging/prod` no la reanuda;
la referencia autorizada solo contempla `dev`. Ver el estado para la restricción exacta.

## Orden copiable para otro agente

> Lee https://github.com/ajunquit/hexagon-template-devops/blob/main/docs/continuidad/INICIO.md y sigue sus enlaces. Verifica
> el estado real de ramas y PR antes de elegir trabajo. Después lee AGENTS y las decisiones del
> repositorio afectado. Continúa el siguiente pendiente autorizado, con un worktree y rama propios,
> pruebas proporcionales y PR al terminar. Conserva cambios ajenos y registra el relevo. No reanudes
> Azure 9C ni amplíes ambientes o publicaciones por interpretar el backlog como una autorización.

Enlace de entrada:
[INICIO.md](https://github.com/ajunquit/hexagon-template-devops/blob/main/docs/continuidad/INICIO.md).
Si la herramienta no carga `AGENTS.md` automáticamente, incluir expresamente esa lectura en la orden.
`CLAUDE.md` importa las reglas donde existe; no se mantienen políticas distintas por modelo.

## Acceso y alcance

Las plantillas, el core, Vision y la fábrica son privados. Autenticar Git/GitHub con una cuenta que
ya tenga acceso; un `404` de un recurso privado puede ser falta de acceso, no ausencia. No solicitar
ni pegar tokens en el chat, documentos o PR. Si no se puede leer una fuente necesaria, indicar cuál
falta y continuar solo el trabajo independiente que sí esté sustentado.

`hexagon-ai-tools`, `movieops` y el DevOps de referencia son públicos. No trasladar allí contexto
reservado, estrategia de Vision, credenciales ni estados. `movieops` es un laboratorio de referencia;
sus scripts no son instrucciones para aplicar recursos de Hexagon.

## Qué se conserva aquí

| Documento | Función |
| --- | --- |
| [Mapa y decisiones](mapa-y-decisiones.md) | Fuentes autorizadas, límites y acuerdos estables. |
| [Estado](estado.md) | Checkpoint mutable con fecha, evidencias y PR; comprobar antes de usar. |
| [Pendientes](pendientes.md) | Trabajo abierto, dependencias y condición de cierre. |
| [Trabajo entre agentes](trabajo-entre-agentes.md) | Ramas, coordinación, comprobación, PR y relevo. |

No se copia el chat completo: contiene hipótesis, preguntas y decisiones después sustituidas.
Conservar decisiones vigentes con fuente, evidencia y estado permite a cualquier modelo continuar
sin convertir conversaciones antiguas en requisitos contradictorios.
