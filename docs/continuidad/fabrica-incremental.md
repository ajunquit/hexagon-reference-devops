# Fábrica incremental: añadir componentes y adoptar productos

Análisis del 2026-11-12 sobre dos pendientes que comparten mecanismo: **F-05**, adoptar productos
creados sin la fábrica (HR, reference), y **F-06**, añadir un repositorio nuevo a un producto en
curso cuando la plataforma incorpore otro tipo de componente. Requiere una decisión de arquitectura
(ADR de plataforma) antes de implementarse. Este documento no autoriza la implementación.

## Requisito

Si la plataforma define un componente nuevo que todo producto debe tener, la fábrica debe poder
añadirlo a un producto existente a partir de su YAML. Repetir la operación con la misma definición
no cambia nada (idempotencia). Los repositorios existentes no se regeneran ni se sobrescriben.

## Qué impide hacerlo hoy

| Pieza | Supuesto actual |
| --- | --- |
| Contrato `hexagon/product/v1` | `templates` exige exactamente business, frontend, backend y DevOps; no admite otros tipos. |
| Catálogo y `PlanBuilder` | `ComponentNames` fija cuatro tipos y la validación de destinos espera cuatro distintos. |
| Lock y journal | El journal exige cuatro componentes; la sincronización valida un lock de cuatro. |
| `create` | Exige un workspace nuevo y rechaza destinos que ya existen. |
| `publish` | Solo crea repositorios nuevos y exige que estén vacíos (`newRepositoryNotEmpty`). |
| Procedencia | `factory-origin.json` enlaza cada componente con el hash del lock de creación. Un lock nuevo rompería esa relación si sustituye al anterior. |

## Diseño propuesto: conciliación del producto

1. **Contrato v2.** Los tipos de componente los declara el catálogo: identificador, si son
   obligatorios, si son desplegables, de qué dependen y qué manifiestos `.hexagon/` aportan. Las
   definiciones v1 se siguen leyendo como v2 equivalentes.
2. **Revisiones de lock.** Business conserva el lock vigente y el historial
   (`.hexagon/locks/<sha256>.json`), y cada revisión enlaza la anterior. Los `factory-origin.json`
   existentes siguen siendo válidos porque su lock permanece en el historial. La sincronización
   acepta cualquier lock de la cadena.
3. **`product reconcile plan/apply/status/publish`.** Compara la definición con el estado real (lock
   vigente, repositorios y procedencia) y clasifica cada componente:

   | Estado | Acción |
   | --- | --- |
   | Falta | Generarlo con su adaptador y publicarlo como repositorio privado con PR borrador, igual que en la creación. |
   | Existe con procedencia | Nada. Las actualizaciones de plantilla siguen por `product sync`. |
   | Existe sin procedencia (HR, reference) | Adopción: PR que añade `factory-origin.json` y `template-sync.json` con una base verificada como ancestro de su rama, sin regenerar el repositorio (F-05). |
   | Sobra en el producto | Solo se informa. Nunca se borra un repositorio. |

   Los cambios que el nuevo componente provoca en los existentes van como PR borrador en esos
   repositorios: la revisión del lock en business y, si es desplegable, el descriptor de DevOps.
4. **Idempotencia.** El plan identifica el estado observado. Si todo está conciliado, termina sin
   escribir. El journal y la reconciliación de respuestas perdidas son los de la publicación actual.

## Recomendación de orden

1. Una ADR de plataforma que sustituya, en este punto, el "producto de cuatro componentes fijos" de
   las ADR 0037/0040 por la conciliación incremental.
2. Primer incremento con un caso real: **adoptar HR** (F-05). Ya ejercita "añadir componentes a un
   producto existente": crea `hexagon-hr-business`, `-dotnet-ml` y `-devops`, y adopta `hexagon-hr-ng`.
   Ver [productos existentes](productos-existentes.md).
3. Generalizar los tipos de componente (F-06) cuando exista una plantilla real de un tipo nuevo, con su
   adaptador y sus pruebas. No se crean tipos ni repositorios vacíos para anticiparlo.

## Decisiones del dueño

- Aprobar la ADR y el contrato v2.
- Primer tipo de componente adicional previsto, si ya se conoce.
- Si un componente nuevo puede ser opcional por producto o siempre obligatorio.
