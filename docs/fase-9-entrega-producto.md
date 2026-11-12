# Fase 9: entrega y verificación del producto completo

La fase 9 incluye **frontend, backend e infraestructura**. Los contratos de la fase 1 ya distinguen
`web` y `backend`; el repositorio DevOps del producto compone y verifica ambos. La mensajería es una
capacidad del backend, no el límite del despliegue de la plataforma.

Las comprobaciones se aplican a los componentes declarados por cada producto. Un producto solo
backend omite el recorrido web; cuando declara frontend y backend, debe acreditar su integración
real. La plantilla no obliga a añadir componentes que el producto no necesita.

9A está integrada: [hosting Azure](hosting-azure.md), artefactos y contratos en los tres repositorios.
9B incorpora [CI y artefactos verificables](ci-y-artefactos.md); sus ejecuciones requieren los accesos
de lectura privados documentados. La infraestructura se valida localmente y con mocks; despliegue
cloud, integración real y promoción siguen pendientes de 9C/9D.
Las fases 1–8 entregaron contratos,
topologías y operación de mensajería. Tener `FrontendHostingRequirements` y cargar configuración
pública no significa que el hosting frontend ya esté aprovisionado. Tampoco implica que API,
Workers, base de datos e identidad tengan un despliegue completo.

## Responsabilidades

| Repositorio | Responsabilidad en la fase 9 |
| --- | --- |
| Frontend del producto | Validar código y contrato; construir una SPA de producción reutilizable, con la API simulada desactivada |
| Backend del producto | Validar código y contratos; construir los artefactos de API/Workers, definir su arranque y comprobar su salud |
| DevOps del producto | Aprovisionar con Terraform, resolver bindings/secretos, desplegar y verificar la combinación exacta de artefactos |

Cada aplicación conserva sus pruebas y puede construir de forma independiente. DevOps coordina la
entrega del producto; un cambio frontend no obliga a recompilar o desplegar backend si el contrato
es compatible. Las aplicaciones no reciben permisos administrativos de infraestructura.

## 9A. Resolver prerrequisitos de hosting y despliegue

Antes de conectar un pipeline de despliegue, se debe:

1. Elegir y documentar el hosting de la SPA, API y Workers, la red y el acceso público/privado para
   una primera composición de referencia. Terraform sigue siendo la herramienta IaC. La elección
   del broker no impone Kubernetes, Argo CD ni el hosting de las aplicaciones.
2. Implementar los módulos y outputs que falten: hosting de archivos estáticos, routing y fallback
   SPA, HTTPS, DNS/dominio según ambiente, reglas de caché, cómputo backend, dependencias de datos e
   identidad y acceso al broker existente. Si RabbitMQ requiere clúster, ese hosting se resuelve
   explícitamente. La política de operación define qué observabilidad debe conectar el hosting.
3. Precisar artefactos y arranque de API/Workers, migraciones y entrega de configuración. Añadir un
   contrato de capacidad solo cuando los inputs/outputs no puedan expresarse de forma segura con
   la composición existente; no asumir que el manifiesto de mensajería declara todo el backend.
4. Verificar la compatibilidad efectiva frontend–API: URL y versión, CORS cuando corresponda,
   autenticación y recorrido de tenant. Resolver bindings de identidad si el frontend los consume,
   con su contrato versionado; la API simulada no acredita esta compatibilidad.
5. Definir el registro de promoción que fijará commits de aplicación, SHA-256 de manifiestos y
   digests/checksums de artefactos. `ProductEnvironment` v1 fija fuentes y contratos; hoy no registra
   digests de imágenes o bundles. Esa trazabilidad de artefactos requiere implementación, no se da
   por existente.

Las decisiones que cambien arquitectura llevan su ADR antes de implementarse. La implementación
de hosting se valida antes de considerar cerrado este prerrequisito.

## 9B. Validación y construcción automatizadas

- **Frontend:** build de producción, pruebas, formato, accesibilidad aplicable y guardrails de
  arquitectura, traducciones y contratos. Publicar un artefacto estático identificable por checksum,
  sin credenciales, configuración física embebida ni API simulada habilitada.
- **Backend:** compilación sin advertencias, pruebas unitarias, de arquitectura e integración,
  coherencia de migraciones y contratos. Identificar por digest los artefactos desplegables elegidos
  en 9A. El core se sigue consumiendo desde los paquetes acordados; esta fase no autoriza su
  publicación remota.
- **DevOps:** validar esquemas y correspondencia entre contratos/políticas, verificar commits y
  SHA-256 remotos, `terraform fmt`, `validate` y pruebas de módulos para los tres proveedores.
  Revisar el plan y proteger los artefactos que puedan contener datos sensibles.

El CI de cada aplicación produce evidencia y artefactos; el despliegue usa esas salidas verificadas,
no una rama mutable ni una build recompilada para cada ambiente.

Evolución pendiente para la automatización permanente con varios productos: sustituir los PAT
personales de lectura de fuentes por una GitHub App con tokens temporales por job, permisos mínimos
y repositorios explícitos. La [guía de CI](ci-y-artefactos.md#acceso-privado-solución-actual-y-evolución-a-github-app)
define la adopción y su verificación. El PAT fine-grained separado sigue siendo la solución actual
para desbloquear 9B; documentar esta evolución no implementa la App ni condiciona el cierre de 9B.

## 9C. Ambiente efímero y recorrido de extremo a extremo

El [motor de ciclo](motor-ciclo-ambiente.md) implementa inventario, orden, revisión de planes y
recuperación con pruebas del protocolo. El [adaptador Terraform/Azure](adaptador-ciclo-azure.md)
añade snapshots confiables, persistencia Blob, lease/CAS y observación, con pruebas locales y HTTP
simulado. Las [reservas efímeras y Genesis/Apocalypse](ciclo-efimero-azure.md) conectan identidad y
contenedor por instancia, etapas revisadas y recuperación. La ejecución cloud y la entrega integral
continúan pendientes; este mecanismo no acredita todavía un ambiente real.

La [entrega verificable y activación del backend](entrega-aplicaciones-azure.md) añade selección de
candidatos, copia OCI sin reconstruir y jobs reconciliables de migraciones/permisos, con planes
separados para mantenimiento y rollout. La [publicación SPA y salud](publicacion-spa-y-salud.md)
añade contenido público verificado y observación de API/Workers. La aceptación integral y limpieza consentida se implementan en [su guía](aceptacion-integral-azure.md); queda pendiente la ejecución Azure real.

La preparación comienza con [bootstrap de plataformas](bootstrap-plataformas.md), según el
[ADR 0013](adr/0013-bootstrap-de-plataformas-declarativo.md) y el
[ADR 0014](adr/0014-bootstrap-ejecutable-con-aislamiento-por-ambiente.md). Se implementan YAML,
validación, planes revisados por etapa, ejecución, migración protegida, configuración GitHub y
verificación con diagnóstico federado manual. La implementación se prueba sin cambios cloud;
cada producto debe ejecutar su definición real y acreditar Verified antes del ciclo del ambiente.

La creación y retirada seguirán [Genesis y Apocalypse](genesis-y-apocalypse.md), según el
[ADR 0012](adr/0012-genesis-y-apocalypse-por-ambiente.md): dos entradas manuales con selector
`dev/staging/prod`, cobertura de frontend/backend y dependencias propias, inventario de estados,
revisión del plan y conservación del bootstrap/plataforma. Su motor de baja también retirará el
ambiente efímero; no se duplica la lógica ni se confunde con un `dev` persistente. Estos workflows
ya implementan el ciclo manual de infraestructura efímera dev/staging; el selector no acredita que
un ambiente esté operativo ni soporte persistente/producción, que se completa en 9D.

DevOps crea un ambiente aislado para la composición de referencia de 9A, con identidad y estado
propios, límites de costo y limpieza verificable incluso cuando una prueba falle. Se debe comprobar:

- recursos, permisos y bindings reales del broker; la aplicación publica/consume sin `Manage`;
- arranque de API y Workers con los outputs y secretos entregados; salud y migraciones esperadas;
- publicación de la SPA y generación de `/runtime-config.json` desde el endpoint real de API;
- que la configuración pública solo contenga claves declaradas y ningún secreto;
- fallback de una ruta Angular profunda y política de caché que no sirva configuración obsoleta;
- que una configuración ausente o inválida impida el bootstrap del frontend;
- acceso desde el navegador a la API real mediante un recorrido soportado con datos ficticios,
  autenticación, versión y tenant según corresponda; sin usar la API simulada;
- entrega de un evento a su Worker y confirmación de la reacción, cuando el recorrido lo requiera;
- limpieza del ambiente y conservación de evidencia técnica saneada.

Las pruebas de módulos cubren los tres proveedores. El primer despliegue efímero integra la
composición de referencia acordada; la matriz completa de proveedores y productos se cierra en la
fase 10. No se promete desplegar tres clouds o tres plataformas de hosting simultáneamente.

## 9D. Promoción por ambiente

Promover la misma SPA compilada y los mismos artefactos backend entre `dev`, `staging` y `prod`,
cambiando solo bindings y configuración del ambiente. La promoción verifica checksums/digests,
compatibilidad de contratos y referencias del producto.

Los pipelines usan identidad federada cuando el proveedor lo permita, permisos mínimos por
repositorio/workload/ambiente, estado remoto con locking, concurrencia controlada, revisión del
plan y aprobación según ambiente. Los secretos no se escriben en el navegador, descriptores,
artefactos versionados ni logs. La política debe limitar qué cambios y artefactos pueden acceder a
credenciales de despliegue; un PR no confiable no hereda esas identidades.

## Definition of Done

- Hosting y artefactos de la composición de referencia implementados y documentados.
- Validaciones de frontend, backend e IaC ejecutadas automáticamente con evidencia.
- Commits, contratos y artefactos desplegados trazables de forma inmutable.
- SPA de producción servida con fallback y configuración pública correcta, sin API simulada.
- API/Workers saludables con bindings reales y sin aprovisionamiento desde las aplicaciones.
- Un recorrido navegador → API real verificado; mensajería incluida cuando corresponda.
- Identidad, permisos, aprobación y aislamiento por ambiente comprobados.
- Ambiente efímero retirado incluso tras fallos; evidencia técnica sin datos sensibles.
- Genesis/Apocalypse con selección explícita, exclusión mutua, planes revisados y baja verificada
  de frontend/backend y dependencias propias; estados y servicios compartidos conservados.
- Promoción sin recompilar la SPA ni los artefactos backend.

La fase 10 conserva estabilización, matriz completa, migración y reversión. Publicar una versión
remota de `Hexagon.Core.*` sigue requiriendo autorización explícita del dueño.

La [publicación SPA y salud de hosting](publicacion-spa-y-salud.md) incorpora PublishWeb/VerifyServing
con el candidato original y evidencia de archivos, configuración pública y API/Workers. Ya están
implementados el E2E autenticado y la limpieza con consentimiento previo, según [aceptación integral](aceptacion-integral-azure.md). La ejecución Azure real sigue pendiente.

## Reanudación de 9C tras la decisión de Auth integrado

La [composición de Auth en una sola base](auth-y-base-compartida.md) es el ajuste previo al
siguiente despliegue. La composición y sus pruebas locales/de protocolo ya están implementadas;
falta adaptar la referencia y ejecutar diagnóstico federado, selección de candidatos, despliegue, aceptación autenticada y retirada
con evidencia. El destino autorizado de la primera referencia es únicamente `dev`. Las funciones
completas del módulo Auth se incorporan por incrementos y no se consideran implementadas por
esta documentación. No se acredita el cierre de 9C hasta completar su ejecución real.
