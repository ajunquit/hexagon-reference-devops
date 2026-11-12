# Mapa y decisiones vigentes

Este mapa orienta; las reglas completas viven en sus fuentes. Una contradicción se resuelve leyendo
la decisión vigente y la instrucción del usuario, no mezclando versiones históricas.

## Repositorios y autoridad

| Repositorio | Responsabilidad y primera lectura |
| --- | --- |
| [hexagon-core-dotnet](https://github.com/ajunquit/hexagon-core-dotnet) | Mecanismos genéricos `Hexagon.Core.*`; AGENTS, README, `docs/roadmap-clean-architecture-api-dotnet.md` y ADR `BE-*`. |
| [hexagon-template-dotnet-ml](https://github.com/ajunquit/hexagon-template-dotnet-ml) | Backend modular: proyectos por capa de cada módulo, Auth editable, outbox/inbox y Workers. AGENTS y `docs/`. |
| [hexagon-template-dotnet-mx](https://github.com/ajunquit/hexagon-template-dotnet-mx) | Backend simple: Domain, Application, Infrastructure y Api, con EF Core. AGENTS y `docs/crear-un-producto.md`. |
| [hexagon-template-ng](https://github.com/ajunquit/hexagon-template-ng) | Frontend Angular y ADR técnicos de plataforma en `docs/adr/`. AGENTS y `docs/producto-en-la-plataforma.md`. |
| [hexagon-template-devops](https://github.com/ajunquit/hexagon-template-devops) | Contratos, Terraform, topología, identidades, entrega y operación. AGENTS, [ruta](../ruta-plataforma.md) y [fase 9](../fase-9-entrega-producto.md). |
| [hexagon-template-business](https://github.com/ajunquit/hexagon-template-business) | Estructura genérica de conocimiento y trazabilidad; no se despliega. AGENTS y `docs/knowledge-governance.md`. |
| [hexagon-product-factory](https://github.com/ajunquit/hexagon-product-factory) | Coordinador de creación desde YAML; no es otra plantilla ni un servicio desplegable. README, AGENTS, catálogo y `docs/ruta.md`. |
| [hexagon-vision](https://github.com/ajunquit/hexagon-vision) | Negocio corporativo, portafolio y decisiones `DEC-*`; no trasladar aquí decisiones técnicas ni copiar su estrategia a plantillas. |
| `hexagon-<producto>-business` | Fuentes, glosario, procesos, reglas y requisitos del producto. Una fuente externa o respuesta de IA no equivale a aprobación. |
| [hexagon-hr-ng](https://github.com/ajunquit/hexagon-hr-ng/tree/dev) | Producto existente. Su AGENTS manda ramas/PR a **dev**, aunque GitHub muestre otra rama por defecto. ROADMAP y ADR propios; normativa requiere verificación oficial vigente. |
| `hexagon-reference-{ng,dotnet-ml,devops}` | Referencia aislada para validar la entrega. No equivale a HR ni a una plataforma productiva. Su estado cloud se comprueba al reanudar la fase autorizada. |
| [hexagon-ai-tools](https://github.com/ajunquit/hexagon-ai-tools) | Skills públicas. Aplicar una skill por su alcance, leyendo su SKILL; no guardar aquí el checkpoint privado de plataforma. |

Las carpetas locales vacías o un nombre previsto no acreditan un repositorio implementado. No crear
HR backend/business/DevOps ni un proyecto de identidad central solo por encontrar sus carpetas.

## Acuerdos que deben preservarse

| Tema | Decisión vigente y fuente |
| --- | --- |
| Inicio del producto | Monolito simple MX o modular ML. React y `dotnet-ms` son futuros, sin prioridad de implementación actual. [ADR 0038](https://github.com/ajunquit/hexagon-template-ng/blob/main/docs/adr/0038-monolitos-simples-y-modulares-con-auth-compartido.md), [BE-0023](https://github.com/ajunquit/hexagon-core-dotnet/blob/main/docs/adr/BE-0023-perfiles-de-monolito-simple-y-modular.md). |
| MX | Cuatro capas ligeras, EF Core, tenant y auditoría. Sin módulos de negocio, eventos, broker, Workers, inbox ni outbox. El ejemplo Notes es ficticio; firma documental pertenece a su producto. |
| ML | Límites Clean Architecture por módulo; contratos para comunicar módulos; outbox transaccional e inbox por handler. [BE-0018](https://github.com/ajunquit/hexagon-core-dotnet/blob/main/docs/adr/BE-0018-bandeja-de-salida-transaccional-por-modulo.md), [BE-0019](https://github.com/ajunquit/hexagon-core-dotnet/blob/main/docs/adr/BE-0019-bandeja-de-entrada-transaccional-por-handler.md). |
| Auth | Código editable del producto: `src/Modules/Auth` con cuatro proyectos en ML; carpetas Auth en las cuatro capas de MX. No restaurar paquetes `Hexagon.Core.Auth.*`. El core conserva mecanismos genéricos. [ADR 0039](https://github.com/ajunquit/hexagon-template-ng/blob/main/docs/adr/0039-auth-editable-en-las-plantillas-backend.md), [BE-0025](https://github.com/ajunquit/hexagon-core-dotnet/blob/main/docs/adr/BE-0025-auth-es-codigo-editable-de-la-plantilla.md). |
| Identidad | Keycloak administra credenciales, sesiones y tokens. Auth administra acceso al producto/tenant. Web usa OIDC Code/PKCE y configuración pública; no emitir tokens propios ni poner secretos en navegador. |
| Base inicial | Una base PostgreSQL por producto, con esquemas `platform`, `auth`, `keycloak` y negocio; usuarios/permisos separados y procesos independientes. No acceder a tablas Keycloak desde el módulo Auth. La separación/centralización futura exige migración explícita de datos e identidad. [ADR 0036](https://github.com/ajunquit/hexagon-template-ng/blob/main/docs/adr/0036-auth-integrado-con-evolucion-a-identidad-central.md), [composición DevOps](../auth-y-base-compartida.md). |
| Mensajería | Azure Service Bus, AWS SNS/SQS y RabbitMQ son adaptadores elegibles; no una dependencia obligatoria de Azure. El contrato no pretende igualar semánticas distintas. [BE-0020](https://github.com/ajunquit/hexagon-core-dotnet/blob/main/docs/adr/BE-0020-transporte-de-eventos-con-adaptadores-seleccionables.md), corregida en aprovisionamiento por BE-0021. |
| Topología | IaC decide colas, DLQ/DLX y políticas por cola/Consumer, independientemente de quién consume. AWS/Rabbit permiten DLQ opcional; Azure conserva DLQ intrínseca. API/Workers solo consumen referencias existentes. AppHost es local y no crea mensajería. [BE-0022](https://github.com/ajunquit/hexagon-core-dotnet/blob/main/docs/adr/BE-0022-contrato-versionado-entre-backend-y-devops.md), fases 4–7 de la ruta. |
| DevOps | Una sola plantilla para MX/ML y posible evolución a servicios; no crear `template-devops-mx/ml/ms`. **Terraform es obligatorio**, no OpenTofu. Identidad de despliegue por producto y ambiente; runtime/mantenimiento/bootstrap separados. [ADR 0002](../adr/0002-terraform-como-herramienta-iac.md), [ADR 0022](../adr/0022-un-devops-para-monolitos-simples-y-modulares.md), [bootstrap](../bootstrap-plataformas.md). |
| Contratos | Aplicaciones declaran necesidades lógicas versionadas en `.hexagon/`; DevOps fija commit y hash, resuelve recursos físicos y secretos. Hosting incluye frontend y backend. Los artefactos se promocionan sin recompilar. |
| Fábrica | YAML elige business, frontend, backend y DevOps; catálogo revisado y lock inmutable. Generación local y publicación privada explícita con PR borrador son etapas distintas. Crear repositorios no despliega. [ADR 0037](https://github.com/ajunquit/hexagon-template-ng/blob/main/docs/adr/0037-fabrica-productos-y-conocimiento-versionado.md), ADR 0040 en la entrega enlazada en el estado. |
| Actualizaciones | Core se actualiza mediante paquetes; plantillas y Auth editable mediante PR, conservando adaptaciones. Guardar procedencia no equivale a tener un motor de sincronización implementado. README/AGENTS/glosario son propios del producto. |

## Prácticas de implementación

El roadmap backend y los AGENTS detallan Clean Architecture, tipos en archivos propios, Result/códigos,
ProblemDetails, CQRS, UUID v7, RLS, permisos y auditoría automática con campos sensibles protegidos.
No se debilitan al elegir MX ni al personalizar Auth. No escribir `TenantId` por SQL de producto ni
omitir filtros. El backend valida configuración al arrancar y ejecuta mantenimiento con identidad
distinta antes del rollout fuera de Development.

Las ADR aceptadas no se reescriben. Una decisión nueva sustituye la anterior, con relación e índice.
Las decisiones técnicas de un producto van en su repositorio; las de negocio en Vision o business,
según ámbito. Un cambio técnico no obliga a inventar una decisión de negocio en Vision: enlazar o
actualizar allí solo lo que tenga efecto sobre su visión/portafolio, sin duplicar ADR.
