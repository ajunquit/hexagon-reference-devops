# Ruta pendiente y condiciones de cierre

Fecha de corte: 2026-11-12. Este listado reúne líneas abiertas de la conversación con sus fuentes.
No es una autorización para ejecutar todas ni fija prioridad de negocio donde el dueño no la decidió.
Leer [estado](estado.md), comprobar PR y elegir un alcance cubierto por la orden actual.

| ID | Pendiente | Dependencia y condición de cierre |
| --- | --- | --- |
| C-01 | Cerrado: fábrica inicial integrada. | Factory #1, ML #43, MX #3, NG #70 y Vision #20 fusionados y comprobados; no repetir la implementación. Ver estado y evidencia. |
| C-02 | Cerrado: relevo integrado. | DevOps #29, Core #27 y Business #2 fusionados. Cada entrega transversal sigue actualizando estado y pendientes por PR. |
| F-01 | Sincronización asistida de plantillas con productos de la fábrica. | **En revisión**: [Factory #2](https://github.com/ajunquit/hexagon-product-factory/pull/2) implementa la comparación base/nueva plantilla/producto. Conserva README, AGENTS, glosarios, procedencia y rutas declaradas, gestiona conflictos y ejecuta checks antes de un PR borrador. Lo acompañan ML #45, MX #5, NG #71 y Business #3. Se cierra al fusionarlos, en ese orden, sin que nadie los fusione automáticamente. Pendiente posterior: la primera sincronización real exige F-04. |
| F-04 | Mover el catálogo a revisiones nuevas de las plantillas. | PR del catálogo con commits completos y generación integral MX/ML. Es el destino de `product sync`; sin él no hay nada que sincronizar. Después, sincronizar los productos de la fábrica que existan publicando un PR borrador por componente con la aprobación del dueño. |
| F-02 | GitHub App para credenciales temporales por ejecución. | Sustituir PAT de lectura de fuentes con permisos mínimos y repos explícitos; migración verificable sin copiar secrets. [Guía CI](../ci-y-artefactos.md). No bloquea la solución actual de token separado. |
| F-03 | Reparación guiada de intenciones ambiguas de publicación. | La fábrica conserva journal y reconcilia respuestas perdidas; un create/PR no encontrado tras una escritura ambigua exige inspección. Automatizar recuperación sin duplicar, sobrescribir ni borrar objetos ajenos, con pruebas negativas. |
| A-01 | UI administrativa Auth y canal de entrega de invitaciones/correo. | Alcances separados del backend ya integrado. Definir necesidades del producto y canal autorizado; no simular envíos ni registrar tokens. [ADR 0039](https://github.com/ajunquit/hexagon-template-ng/blob/main/docs/adr/0039-auth-editable-en-las-plantillas-backend.md), [BE-0025](https://github.com/ajunquit/hexagon-core-dotnet/blob/main/docs/adr/BE-0025-auth-es-codigo-editable-de-la-plantilla.md). Prioridad pendiente de decidir. |
| A-02 | Identidad centralizada `hexagon-auth`. | Evolución futura desde Auth integrado. Definir propiedad de datos y migración conservando issuer/sub, pertenencias, permisos y pruebas; no crear otro sistema paralelo de tokens ni duplicar tablas Keycloak. Prioridad pendiente. |
| D-9C | Validación real del producto completo en Azure. | **Pausada**. Solo dev de referencia cuando el dueño retome este alcance: composición Auth/base única, diagnóstico, identidad, candidatos, entrega SPA/API/Workers, E2E autenticado y retirada verificable. [Fase 9](../fase-9-entrega-producto.md), [Auth/base](../auth-y-base-compartida.md). No cerrar con mocks o Published. |
| D-9D | Ambientes persistentes y promoción. | Después de evidencia 9C y definición autorizada de ambientes. Promover los mismos artefactos por digest/checksum, con identidad federada, políticas/estado independientes y revisión/aprobación. No crear staging/prod de la referencia para adelantar esta fase. |
| D-10 | Estabilización, matriz de proveedores y publicación necesaria. | Tras validar entrega real: compatibilidad, adopción, migración/reversión y evidencias de escenarios acordados. Publicar core solo si es necesario y cubierto por autorización/procedimiento, no por el nombre de la fase. |
| P-01 | Adopción en productos existentes, incluido HR. | HR frontend ya recibió configuración runtime. Revisar el delta posterior de plantilla y necesidades reales; no regenerar ni sobrescribir su repo. `product sync` rechaza productos sin `.hexagon/factory-origin.json`: adoptarlo exige reconstruir y revisar su base de plantilla y su identidad. Perfil, backend, business y DevOps de un producto requieren alcance/definición propios. |
| T-01 | React y microservicios. | Opciones futuras deshabilitadas. Se necesitan plantillas reales, adaptadores, catálogo, contratos y pruebas; no crear repos vacíos para marcar soporte. Todo producto comienza como monolito salvo nueva decisión que lo justifique. |

## Qué no es un pendiente nuevo

- Outbox/inbox, adaptadores Azure/AWS/Rabbit, contratos Aplicación–DevOps y topología por cola
  existen en sus perfiles/capas correspondientes. Cambiarlos exige un problema concreto y evidencia.
- Auth ya debe verse en ambas plantillas backend. Si una copia local muestra paquetes Core.Auth o
  no contiene el módulo/carpeta, comprobar rama y revisión antes de volver a implementarlo.
- Crear versiones DevOps MX/ML/MS y usar OpenTofu contradice decisiones vigentes.
- La idea de firma documental motivó MX; no se decidió aquí crear un producto con un nombre, alcance
  normativo y prioridades determinados. Su negocio no se implementa en el core ni en la plantilla.

## Cómo escoger el siguiente trabajo

C-01 y C-02 están cerrados al corte. Verificar primero si F-01 quedó integrado. Después, atender el pendiente que el dueño
priorice; una orden genérica no levanta D-9C ni el límite dev. Para una entrega local autorizada,
resolver decisiones rutinarias y avanzar sin volver a pedir permisos ya concedidos. Si falta una
decisión de producto o un permiso necesario no cubierto, registrar la pregunta concreta y continuar
la parte independiente que sí se pueda completar.
