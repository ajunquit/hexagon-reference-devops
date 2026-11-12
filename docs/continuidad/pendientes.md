# Ruta pendiente y condiciones de cierre

Fecha de corte: 2026-11-12. Este listado reúne líneas abiertas de la conversación con sus fuentes.
No es una autorización para ejecutar todas ni fija prioridad de negocio donde el dueño no la decidió.
Leer [estado](estado.md), comprobar PR y elegir un alcance cubierto por la orden actual.

| ID | Pendiente | Dependencia y condición de cierre |
| --- | --- | --- |
| C-01 | Cerrado: fábrica inicial integrada. | Factory #1, ML #43, MX #3, NG #70 y Vision #20 fusionados y comprobados; no repetir la implementación. Ver estado y evidencia. |
| C-02 | Cerrado: relevo integrado. | DevOps #29, Core #27 y Business #2 fusionados. Cada entrega transversal sigue actualizando estado y pendientes por PR. |
| F-01 | Cerrado: sincronización asistida integrada. | Fusionados Factory #2, ML #45, MX #5, NG #71, Business #3 y DevOps #30. Historial: [Factory #2](https://github.com/ajunquit/hexagon-product-factory/pull/2) implementa la comparación base/nueva plantilla/producto. Conserva README, AGENTS, glosarios, procedencia y rutas declaradas, gestiona conflictos y ejecuta checks antes de un PR borrador. Lo acompañan ML #45, MX #5, NG #71 y Business #3. Se cierra al fusionarlos, en ese orden, sin que nadie los fusione automáticamente. Pendiente posterior: la primera sincronización real exige F-04. |
| F-04 | Cerrado: catálogo en las revisiones vigentes. | [Factory #3](https://github.com/ajunquit/hexagon-product-factory/pull/3) fusionado, con generación integral MX/ML en verde. Cada revisión nueva de una plantilla repite este recorrido: PR del catálogo con generación integral. |
| F-02 | GitHub App para credenciales temporales por ejecución. | Sustituir PAT de lectura de fuentes con permisos mínimos y repos explícitos; migración verificable sin copiar secrets. [Guía CI](../ci-y-artefactos.md). No bloquea la solución actual de token separado. |
| F-03 | Reparación guiada de intenciones ambiguas de publicación. | La fábrica conserva journal y reconcilia respuestas perdidas; un create/PR no encontrado tras una escritura ambigua exige inspección. Automatizar recuperación sin duplicar, sobrescribir ni borrar objetos ajenos, con pruebas negativas. |
| Q-01 | Cerrado: cleanup intermitente de RabbitMQ. | Core #28, ML #46 y Factory #5 fusionados. La generación integral ML pasa al primer intento. |
| F-05 | Cerrado: adopción de productos existentes. | Factory #6 fusionado (ADR 0041, primer incremento). Primer uso: la H1 de HR publicada el 2026-11-12. |
| F-05b | Cerrado: adopción de copias sin historia compartida. | Factory #7 fusionado (`15b2fd7`). Base por coincidencia exacta del árbol del commit raíz; une la historia (merge `ours`) solo en repositorios privados. Primer uso: `hexagon-reference-devops` en R-01. |
| F-06 | Añadir componentes nuevos a productos en curso desde su YAML, de forma idempotente. | Mismo mecanismo que F-05 (`product reconcile`): contrato v2 con tipos de componente en el catálogo e historial de locks, sin borrar repositorios. Ver [fábrica incremental](fabrica-incremental.md). Se implementa cuando exista una plantilla real de un tipo nuevo. |
| F-07 | Cerrado: `product sync` y `template/main` conviven. | Factory #4 fusionado: segundo padre con la revisión integrada y base detectada en la historia. Ver [productos existentes](productos-existentes.md#f-07-sincronización-coherente-con-templatemain). |
| A-01 | UI administrativa Auth y canal de entrega de invitaciones/correo. | Alcances separados del backend ya integrado. Definir necesidades del producto y canal autorizado; no simular envíos ni registrar tokens. [ADR 0039](https://github.com/ajunquit/hexagon-template-ng/blob/main/docs/adr/0039-auth-editable-en-las-plantillas-backend.md), [BE-0025](https://github.com/ajunquit/hexagon-core-dotnet/blob/main/docs/adr/BE-0025-auth-es-codigo-editable-de-la-plantilla.md). Prioridad pendiente de decidir. |
| A-02 | Identidad centralizada `hexagon-auth`. | Evolución futura desde Auth integrado. Definir propiedad de datos y migración conservando issuer/sub, pertenencias, permisos y pruebas; no crear otro sistema paralelo de tokens ni duplicar tablas Keycloak. Prioridad pendiente. |
| D-9C | Validación real de **reference en Azure `dev`**. | **Pausada.** Es el estado esperado decidido por el dueño (2026-11-12), pero requiere orden expresa. R-01 completó reference con las revisiones vigentes; el descriptor `dev` de su DevOps debe actualizarse a los commits que se desplieguen. Solo `dev`: composición Auth/base única, diagnóstico, identidad, candidatos, entrega SPA/API/Workers, E2E autenticado y retirada verificable. [Fase 9](../fase-9-entrega-producto.md), [Auth/base](../auth-y-base-compartida.md). No cerrar con mocks o Published. |
| D-9D | Ambientes persistentes y promoción. | Después de evidencia 9C y definición autorizada de ambientes. Promover los mismos artefactos por digest/checksum, con identidad federada, políticas/estado independientes y revisión/aprobación. No crear staging/prod de la referencia para adelantar esta fase. |
| D-9A-AWS | Hosting de aplicaciones en AWS para HR. | Falta en la plantilla DevOps: hoy solo hay hosting Azure. Diseñar y probar localmente el módulo AWS (SPA, API/Workers, PostgreSQL, Keycloak, secretos e identidad por producto y ambiente) con contratos y pruebas, sin desplegar. Las decisiones de servicios AWS y de cuenta/región son del dueño. |
| D-9C-AWS | Validación real de **HR en AWS `dev`**. | Estado esperado decidido por el dueño (2026-11-12). Depende de H1 publicada, D-9A-AWS y una orden expresa de despliegue. Solo `dev`; staging y prod llegarán después con Genesis (D-9D). Antes de configurar su environment `dev`, el dueño hace público `hexagon-hr-devops` (decisión del 2026-11-12, mientras el plan sea GitHub Free). |
| R-01 | Cerrado salvo integrar dotnet-ml #6: reference completo con la fábrica. | Business creado; `-ng`, `-dotnet-ml` y `-devops` adoptados; `-ng` y `-devops` sincronizados al catálogo vigente; backend sincronizado en [dotnet-ml #6](https://github.com/ajunquit/hexagon-reference-dotnet-ml/pull/6). Factory #7, #8 y #9 fusionados. Detalle en el [estado](estado.md). El nombre `reference` se conserva y su DevOps sigue público. |
| G-01 | Pasar a GitHub Pro y volver privados los DevOps de producto. | Decisión futura del dueño. Con Pro, los environments funcionan en repositorios privados. Primero se contrata Pro y después se cambia la visibilidad; luego se comprueba que los environments, sus reglas y sus secretos siguen activos, porque en Free GitHub los ignora en un repositorio privado. |
| D-10 | Estabilización, matriz de proveedores y publicación necesaria. | Tras validar entrega real: compatibilidad, adopción, migración/reversión y evidencias de escenarios acordados. Publicar core solo si es necesario y cubierto por autorización/procedimiento, no por el nombre de la fase. |
| P-01 | Adopción de productos existentes: HR y reference. | **H0 cerrada**: [HR #50](https://github.com/ajunquit/hexagon-hr-ng/pull/50) trajo hexagon-template-ng #60–#72 a `dev`, sin el ejemplo Sales y con OIDC sin activar (decisiones del dueño), y añadió CI a HR. Sigue H1 (adopción en la fábrica, F-05, requiere ADR) y luego H2–H4. Ruta y decisiones en [productos existentes](productos-existentes.md). No regenerar ni sobrescribir `hexagon-hr-ng`. Decisiones para H1–H3 (2026-11-12): mensajería AWS SNS/SQS y migración del conocimiento según [conocimiento de HR](hr-conocimiento.md). `hexagon-hr-business` existe desde el 2026-11-12 ([#1](https://github.com/ajunquit/hexagon-hr-business/pull/1), inicialización en borrador). **H1 integrada** (2026-11-12): hexagon-hr-ng #51, hexagon-hr-business #2, hexagon-hr-dotnet-ml #1 y hexagon-hr-devops #1, con CI de `main` en verde. **H2 publicada**: business #3, hr-ng #52 y Vision #21, a integrar en ese orden. Después: H3 (backend) y H4 (despliegue, D-9C-AWS). |
| T-01 | React y microservicios. | Opciones futuras deshabilitadas. Se necesitan plantillas reales, adaptadores, catálogo, contratos y pruebas; no crear repos vacíos para marcar soporte. Todo producto comienza como monolito salvo nueva decisión que lo justifique. |

## Orden aceptado por el dueño (2026-11-12)

1. Integrar la H1 de HR (P-01). **Hecho.**
2. H2: conocimiento de HR en business (P-01). **Publicada**; falta integrar business #3, hr-ng #52 y Vision #21.
3. F-05b y R-01: reference completo con la fábrica. **Hecho**, salvo integrar dotnet-ml #6.
4. D-9A-AWS: hosting AWS.
5. D-9C (reference en Azure `dev`) y D-9C-AWS (HR en AWS `dev`), cada uno con su orden expresa.

## Qué no es un pendiente nuevo

- Outbox/inbox, adaptadores Azure/AWS/Rabbit, contratos Aplicación–DevOps y topología por cola
  existen en sus perfiles/capas correspondientes. Cambiarlos exige un problema concreto y evidencia.
- Auth ya debe verse en ambas plantillas backend. Si una copia local muestra paquetes Core.Auth o
  no contiene el módulo/carpeta, comprobar rama y revisión antes de volver a implementarlo.
- Crear versiones DevOps MX/ML/MS y usar OpenTofu contradice decisiones vigentes.
- La idea de firma documental motivó MX; no se decidió aquí crear un producto con un nombre, alcance
  normativo y prioridades determinados. Su negocio no se implementa en el core ni en la plantilla.

## Cómo escoger el siguiente trabajo

C-01, C-02, F-01, F-04, Q-01 y F-07 están cerrados al corte, junto con la H0 de HR. No hay entrega en curso. Después, atender el pendiente que el dueño
priorice; una orden genérica no levanta D-9C ni el límite dev. Para una entrega local autorizada,
resolver decisiones rutinarias y avanzar sin volver a pedir permisos ya concedidos. Si falta una
decisión de producto o un permiso necesario no cubierto, registrar la pregunta concreta y continuar
la parte independiente que sí se pueda completar.
