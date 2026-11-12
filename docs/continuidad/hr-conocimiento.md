# Conocimiento de HR: dónde vive y qué se migra

Análisis del 2026-11-12, hecho a pedido del dueño. Recorre los repositorios Hexagon con contenido de
HR y clasifica cada pieza según su sitio. La migración se ejecuta en la fase H2, cuando exista
`hexagon-hr-business`. Este documento es la guía, no la ejecución. Ver la ruta en
[productos existentes](productos-existentes.md).

## Criterio

| Destino | Qué contiene | Fuente de la regla |
| --- | --- | --- |
| `hexagon-vision` | Negocio **corporativo**: visión, portafolio, público, canales, modelo comercial, precios y decisiones `DEC-*`, que no se reescriben. | AGENTS de Vision. |
| `hexagon-hr-business` | Conocimiento del **producto**: fuentes (con fecha y confianza), contexto, glosario, procesos, reglas, requisitos, features y decisiones de producto. | Plantilla business y su `knowledge-governance`. |
| `hexagon-hr-ng` y `hexagon-hr-dotnet-ml` | Decisiones **técnicas** (ADR del repositorio), el mapeo del glosario a claves, rutas y código, y la documentación de cada módulo. | AGENTS de cada repositorio. |

Para no duplicar, cada pieza vive en un único sitio y los demás la enlazan. Un ADR o una `DEC` ya
aceptados no se reescriben ni se mueven: se indexan desde business, y las decisiones nuevas se
registran donde corresponda.

## Inventario

### `hexagon-vision`

| Pieza | Tipo | Destino |
| --- | --- | --- |
| `productos/hr/ficha.md` | Público, problema, canales, modalidades, planes, precio de referencia, relación con otros productos, riesgos y pendientes comerciales. | **Se queda.** Al crear business, enlazarlo y resumir allí el alcance funcional (el mapa de 99 módulos). |
| `productos/hr/investigacion/2026-10-informe-original.md` (916 líneas) | Fuente original de la investigación normativa. | **Pasa** a `sources/` de business, sin modificar, con su entrada en `catalog.yaml` (fecha y confianza). Vision lo sustituye por un enlace. |
| `productos/hr/investigacion/2026-10-investigacion-normativa.md` | Primera investigación, ya sustituida. | **Pasa** a `sources/` marcada como sustituida. |
| `productos/hr/investigacion/2026-10-13-paquete-normativo.md` | Resumen de los hallazgos con efecto de negocio (por ejemplo la biometría). | **Se divide.** El resumen de producto pasa a `docs/context/` de business; Vision conserva solo el riesgo comercial (biometría frente a la oferta de relojes), con enlace. |
| `DEC-0006` (sector privado y público), `DEC-0008` (un producto por país) | Decisiones de portafolio. | **Se quedan.** Business las enlaza desde `docs/context/`. |
| `DEC-0007` (validación de reglas legales) | Regla de gobierno del conocimiento de HR. | **Se queda** (no se reescribe). Business la aplica en sus reglas de verificación y la enlaza. |
| `DEC-0011` (desconexión digital, en propuesta) | Decisión de negocio con efecto en el producto. | **Se queda** mientras se decide. Cuando se acepte, el requisito pasa a `docs/requirements/` de business. |
| `ideas/2026-10-18-hr-trabajo-del-hogar.md` | Pregunta de portafolio: ¿módulo, versión aparte o socios? | **Se queda** como idea hasta que se decida. |

### `hexagon-hr-ng`

| Pieza | Tipo | Destino |
| --- | --- | --- |
| `normativa/referencia/` (13 archivos, corte 2026-10-13) | Paquete normativo de referencia por área. | **Pasa** a `sources/` de business, sin modificar, con su catálogo. |
| `normativa/README.md` | Uso de la referencia y estado de verificación de cada regla. | **Pasa** a `docs/domain/business-rules/` de business. El estado de verificación es conocimiento del producto. |
| `ROADMAP.md`, "Flujos de aprobación" | Vocabulario, configuración y procesos. | **Pasa** a `docs/processes/` y `docs/domain/` de business. |
| `ROADMAP.md`, "Mapa de módulos" | Alcance funcional por área y estado de cada módulo. | **Se divide.** El alcance y la prioridad pasan a `docs/features/` de business; la ruta, la clave del menú y el estado de implementación se quedan en el frontend. |
| `ROADMAP.md`, "Cumplimiento normativo: requisitos técnicos" | Requisitos técnicos. | **Se quedan** en el frontend. Los de backend pasarán a `hexagon-hr-dotnet-ml` en H3. |
| `AGENTS.md`, glosario | Términos del negocio, su traducción y su clave o ruta. | **Se divide.** El glosario canónico (término, inglés, definición y fuente, incluida la distinción cargo/puesto) pasa a `docs/domain/glossary.md` de business; AGENTS conserva el mapeo a claves y rutas y enlaza el glosario. |
| `adr/HR-0001`, `HR-0003`, `HR-0007` | Decisiones técnicas del frontend: entrada, menú y tenant. | **Se quedan.** |
| `adr/HR-0002` | Ya trasladada a Vision. | Sin cambio. |
| `adr/HR-0004`–`HR-0006`, `HR-0008`–`HR-0022` | Decisiones del dominio: jerarquía de datos, entidades, catálogos, datos legales, cambios societarios, Courses, módulos del paquete normativo, desconexión digital. | **Se quedan** (no se reescriben). Business las indexa en `docs/decisions/` con enlace. Las decisiones de dominio nuevas se registran en business, y el backend las aplica con sus ADR técnicos. |
| `src/app/features/*/README.md` | Documentación técnica de cada módulo. | **Se quedan.** |

### Plantillas, core y fábrica

Solo usan HR como **ejemplo de nombre**: `hexagon-hr`, el prefijo `HR-0001`, "en HR: Organización,
Colaboradores, Nómina" y "Hexagon HR API". No contienen conocimiento del producto, así que no se
migra nada. La guía de la fábrica nombra HR como caso de adopción; es coordinación, no conocimiento
de producto.

## Cómo se ejecuta (H2)

Requiere que exista `hexagon-hr-business`, creado en H1 con procedencia de la fábrica. Son tres PR
coordinados, que el dueño revisa antes de fusionar:

1. `hexagon-hr-business`: fuentes sin modificar con su catálogo, contexto, glosario canónico,
   procesos, reglas con su estado de verificación, alcance funcional e índice de decisiones. Cada
   documento declara su fuente; nada se marca como aprobado sin evidencia.
2. `hexagon-hr-ng` (PR a `dev`): sustituye `normativa/` y las secciones movidas de `ROADMAP.md` por
   enlaces, y ajusta AGENTS y README para que apunten a business.
3. `hexagon-vision`: la ficha enlaza business, y la investigación movida se sustituye por un enlace
   con su fecha. Las `DEC` no cambian.

Se integra primero business. Los otros dos solo enlazan contenido que ya exista.

**Publicada el 2026-11-12:** [hexagon-hr-business #3](https://github.com/ajunquit/hexagon-hr-business/pull/3),
[hexagon-hr-ng #52](https://github.com/ajunquit/hexagon-hr-ng/pull/52) y
[hexagon-vision #21](https://github.com/ajunquit/hexagon-vision/pull/21).

## Decisiones del dueño (2026-11-12)

- El backend de HR usará **AWS SNS/SQS** como proveedor de mensajería.
- El conocimiento de producto de HR pasa a `hexagon-hr-business`, con el criterio de este documento.
  Lo corporativo se queda en Vision, enlazado.
