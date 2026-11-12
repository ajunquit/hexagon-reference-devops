# Estado verificable para el siguiente relevo

**Fecha de corte: 2026-11-12.** Comprobar GitHub antes de actuar: un PR puede fusionarse o cambiar
después de esta fotografía. Este archivo distingue código, validación local, CI y operación real.

## Trabajo activo: cerrar R-01 y seguir con D-9A-AWS

**Ruta aceptada por el dueño (2026-11-12)**, en este orden:

1. Publicar la H1 de HR. **Hecho e integrado.**
2. H2: migrar el conocimiento de HR a `hexagon-hr-business`, según el [inventario](hr-conocimiento.md).
   **Hecho e integrado.**
3. F-05b y R-01: adoptar copias sin historia compartida y completar reference con la fábrica.
   **Hecho**: falta integrar el último PR de sincronización (backend).
4. D-9A-AWS: hosting de aplicaciones en AWS en la plantilla DevOps, probado en local.
5. Desplegar en `dev`, cada uno con una orden expresa: reference en Azure (D-9C) y HR en AWS (D-9C-AWS).

La validación Azure 9C sigue **pausada** hasta esa orden.

### R-01: reference completo con la fábrica (2026-11-12)

Reference tiene sus cuatro componentes con procedencia de la fábrica, y tres de ellos ya están al
día con el catálogo vigente. Fábrica `main` en `2a264ba`. Definición: `name: reference`, Azure
Service Bus, Keycloak, solo `dev` (`.worktrees/r01/reference.yaml`, en la máquina de trabajo).

| Paso | PR | Estado al corte |
| --- | --- | --- |
| Adopción de copias sin historia compartida (F-05b) | Factory #7 | Fusionado. |
| Descriptores al adoptar un DevOps que nunca registró su producto | Factory #8 | Fusionado. Hallazgo de R-01: reference no tenía descriptor `dev`. |
| Render de revisiones del backend anteriores a `-Slug` | Factory #9 | Fusionado. Hallazgo de R-01: la base `7ae1e54` no admitía `-Slug`. |
| Conciliación: business creado (privado); adopción de `-ng`, `-dotnet-ml` y `-devops` | business #1, ng #2, dotnet-ml #5, devops #2 | Fusionados con merge, porque el descriptor `dev` enlaza los commits de adopción. CI de `main` en verde. |
| Sincronización de `-ng`: `76fd4a7` → `a6b1ea4` | [ng #3](https://github.com/ajunquit/hexagon-reference-ng/pull/3) | Fusionado. Sin conflictos. |
| Sincronización de `-devops`: `0c96847` → `32ce377` | [devops #3](https://github.com/ajunquit/hexagon-reference-devops/pull/3) | Fusionado. CI de `main` en verde. Un conflicto, `docs/bootstrap-plataformas.md`, resuelto con el texto de la plantilla ("ambientes declarados", que cubre "solo `dev`"). Sin historia de la plantilla (repositorio público). |
| Sincronización de `-dotnet-ml`: `7ae1e54` → `d3bcb24` | [dotnet-ml #6](https://github.com/ajunquit/hexagon-reference-dotnet-ml/pull/6) | **Abierto**, en borrador. Pruebas locales y CI del PR en verde. Dos conflictos resueltos con el lado de la plantilla: el core pasa de `5773776` a `ba5a99f`, que lo contiene, y `.hexagon/product.yaml` apunta a `d3bcb24` con los mismos datos. |

`hexagon-reference-devops` tiene el secreto `HEXAGON_APPLICATIONS_READ_TOKEN`, de solo lectura sobre
`-ng` y `-dotnet-ml`. Business no tiene CI.

**Revisión opcional del dueño:** la plantilla cambió `AGENTS.md`, `README.md` y `CHANGELOG.md` de
`-ng`, `-dotnet-ml` y `-devops`. La sincronización no los toca porque son del producto; cada informe
de sincronización muestra la diferencia, por si reference quiere adoptarla.

### H1 de HR integrada (2026-11-12)

Fusionados por el dueño: hexagon-hr-ng #51 (a `dev`), hexagon-hr-business #1 y #2, hexagon-hr-dotnet-ml
#1 y hexagon-hr-devops #1. Con los secretos `HEXAGON_CORE_READ_TOKEN` (backend) y
`HEXAGON_APPLICATIONS_READ_TOKEN` (DevOps) configurados por el dueño, el CI de `main` está en verde:

- hexagon-hr-dotnet-ml, Backend CI, run `43262836518` sobre `b7e1804`;
- hexagon-hr-devops, DevOps CI, run `43262843700` sobre `373531d`: compilación, base de datos y
  mensajería con Azure Service Bus, AWS SNS/SQS y RabbitMQ.

HR tiene ya sus cuatro componentes con procedencia de la fábrica.

### H2 de HR publicada (2026-11-12)

Tres PR coordinados, que se integran **en este orden**:

| Orden | PR | Qué es | Estado al corte |
| --- | --- | --- | --- |
| 1 | [hexagon-hr-business #3](https://github.com/ajunquit/hexagon-hr-business/pull/3) | Fuentes sin modificar (SRC-0001..0015, con SHA-256 en `sources/catalog.yaml`), contexto, glosario canónico, flujos de aprobación, estado de verificación de reglas, mapa de módulos e índice de decisiones. | Abierto; el repositorio no tiene CI. |
| 2 | [hexagon-hr-ng #52](https://github.com/ajunquit/hexagon-hr-ng/pull/52) | A `dev`: retira `normativa/referencia/`, deja `normativa/README.md` como puntero, remite AGENTS, README y ROADMAP a business. HR-0021 solo cambia su enlace. | Abierto; lints y formato en verde en local. |
| 3 | [hexagon-vision #21](https://github.com/ajunquit/hexagon-vision/pull/21) | La ficha enlaza los cuatro repositorios; la investigación de octubre queda como puntero en su ruta (DEC-0007 sigue enlazando); el resumen del paquete se divide y Vision conserva solo los efectos de negocio. Las DEC no cambian. | Borrador. |

Los enlaces a business apuntan a `main`: funcionan cuando se integre business #3. Worktrees en
`C:/Workspace/hexagon/.worktrees/` (`hr-business-h2`, `hr-ng-h2`, `vision-hr-h2`).

### Evidencia de Q-01 (integrada)

- Diagnóstico: la colección de mensajería repetida en un backend ML con RabbitMQ falló 3 de 6 veces.
  El detalle del `AggregateException` muestra `ObjectDisposedException` en
  `AutorecoveringChannel.CloseAsync` (RabbitMQ.Client 7.2.2) desde `RabbitMqConsumer.StopAsync`.
- Con el core corregido, empaquetado localmente (`0.6.0-dev`, sin publicar): **10 de 10** ejecuciones
  sin fallos en el mismo producto, y la plantilla ML aprobó `Test-Backend.ps1` completo. La
  generación integral ML con el catálogo de Factory #5 pasó al primer intento.

### Contexto registrado en esta entrega

- HR es un producto real: `hexagon-hr-ng` trabaja en `dev`, se actualiza con `git merge template/main`
  y está 12 PR de la plantilla por detrás. No tiene business, backend ni DevOps. Ruta por fases y
  decisiones pendientes en [productos existentes](productos-existentes.md).
- `hexagon-reference-*` están publicados, sin procedencia de la fábrica y nunca desplegados a `dev`:
  forman parte de D-9C.
- Requisito nuevo: añadir repositorios a productos en curso desde su YAML (F-06), diseñado junto con
  la adopción (F-05) en [fábrica incremental](fabrica-incremental.md).

### Evidencia de F-04 (integrada)

- Commits fijados: `main` vigente de cada plantilla tras integrar F-01, con la CI en verde. La CI de
  DevOps `32ce377` falló una vez porque RabbitMQ no estuvo listo en tres minutos (cambio solo
  documental) y su repetición pasó.
- Generación integral con la revisión `169a6fc` de la fábrica, en `C:/Workspace/hexagon/.worktrees/catalog-integral-{mx,ml}`
  (máquina de trabajo). MX completo al primer intento: 145 pruebas de navegador, 18 backend,
  migraciones y suite DevOps. ML: 145 + 128 con RabbitMQ, migraciones y suite DevOps. El backend ML
  necesitó un segundo intento por el cleanup intermitente de RabbitMQ (Q-01); el primero se conserva.

### Evidencia de F-01 (integrada)

- Revisiones funcionales `5d5801d`, `be13c7e` y `7dbea67` de la fábrica; la última es el código final.
  Sin publicar ramas, PR ni paquetes: no hay ningún producto de la fábrica en GitHub.
- Productos ficticios de `C:/Workspace/hexagon/.worktrees/factory-final-{ml,mx}` (máquina de trabajo) sincronizados localmente desde los commits
  del catálogo hasta el `main` de cada plantilla, con una rama de catálogo desechable no publicada.
  Business, Angular (145 pruebas), DevOps (suite completa), backend ML (128 pruebas con RabbitMQ y
  migraciones) y MX (18 pruebas y migraciones), todos en verde.
- Un clon Angular personalizado comprobó un conflicto en un archivo renombrado, una eliminación
  conservada, una ruta declarada y el glosario de AGENTS intacto; tras resolver, checks completos.
- Hallazgos corregidos en la fábrica, con prueba: `UserSecretsId` aleatorios del generador ML y orden
  variable de `.hexagon/product-origin.json` en MX. Los intentos fallidos se conservan.
- Entorno: la suite DevOps exige Terraform 1.10 o posterior; se usó el binario 1.17.1 firmado de
  `%TEMP%/hexagon-terraform-1.17.1`. Las suites Docker no deben correr en paralelo con otras suites,
  porque el cleanup de RabbitMQ falla.
- Generación integral ML con el código final `7dbea67` y el catálogo de la entrega: en verde (128 + 145 pruebas, migraciones y suite DevOps).
- Cambios locales no publicados en la máquina de trabajo: worktrees `factory-sync-e2e*` con el commit
  de catálogo desechable (no publicar) y workspaces `sync-e2e/*` y `sync-integral-ml`, que son
  evidencia. No contienen trabajo pendiente de entregar.

## Evidencia de la fábrica

- Revisión funcional comprobada: `61b7a96` de `hexagon-product-factory`; cambios posteriores de esta
  entrega añaden enlaces AGENTS y documentación de relevo. Consultar su
  [evidencia](https://github.com/ajunquit/hexagon-product-factory/pull/1) para el HEAD final.
- Build sin advertencias, 51 pruebas, formato y ejemplos MX/ML aprobados en esa revisión.
- Generaciones reales MX y ML de business, frontend, backend y DevOps terminadas con exit code 0.
  Core empaquetado desde un pin inmutable; 18 pruebas MX y 128 ML con RabbitMQ, migraciones sin
  cambios pendientes, guardrails/build/145 pruebas de navegador en cada perfil y ambas suites DevOps
  aprobadas. Una comprobación independiente con `git cat-file` verificó que todos los hashes de los
  descriptores coinciden con los blobs del commit. Solo `dev` declarado en ambos perfiles.
- Se conservaron intentos fallidos y se corrigieron normalización de campos opcionales, rutas
  largas Git en Windows y hashes DevOps calculados desde el commit, evitando diferencias CRLF.
  Un intento ML falló en cleanup; no se suprimió el fallo. Su repetición completa aprobó los casos.
- La publicación se prueba con dobles de protocolo y Git local: privado/borrador, 403/404, colisiones,
  respuestas perdidas y reanudación. No se crearon productos de prueba en GitHub ni recursos cloud.
- Esta entrega no publicó versiones de paquetes. Publicación de repositorios, CI y despliegue
  continúan siendo estados distintos.

Las fases 1–4 de la fábrica están implementadas, verificadas e integradas. De la fase 5, la
sincronización asistida está en [Factory #2](https://github.com/ajunquit/hexagon-product-factory/pull/2); GitHub App (F-02) y reparación guiada (F-03)
siguen pendientes.

El YAML admite business, Angular, backend MX o ML y un DevOps común. React/MS están deshabilitados.
El flujo es `pwsh ./hexagon.ps1 product validate/plan/create/status/publish`, con los argumentos exactos
del README de la fábrica; la barra separa subcomandos, no es un comando literal. `publish` requiere
el hash del lock y crea repos privados con PR borrador. No ejecuta Terraform sobre cuentas reales.

## Ya integrado: no repetir

| Capacidad | Evidencia |
| --- | --- |
| Auth propiedad de las plantillas/productos, retirado de Core.Auth | [Core #26](https://github.com/ajunquit/hexagon-core-dotnet/pull/26), [ML #42](https://github.com/ajunquit/hexagon-template-dotnet-ml/pull/42), [MX #2](https://github.com/ajunquit/hexagon-template-dotnet-mx/pull/2). |
| Regla de propiedad Auth y guías de plataforma | [NG #69](https://github.com/ajunquit/hexagon-template-ng/pull/69), ADR 0039 y BE-0025; [Vision #19](https://github.com/ajunquit/hexagon-vision/pull/19). |
| Estructura documental business | [Business #1](https://github.com/ajunquit/hexagon-template-business/pull/1). |
| Conflictos previos resueltos e integración de su alcance | ML #40, DevOps #27 y NG #67 fusionados. No abrir otra implementación equivalente. |
| HR: actualización de configuración frontend en runtime | [HR #49](https://github.com/ajunquit/hexagon-hr-ng/pull/49), fusionado a `dev`; nuevas mejoras se revisan por adopción, no se heredan solas. |

Auth incluye usuarios del tenant, roles, invitaciones y permisos en backend; Keycloak conserva
identidades y tokens. UI administrativa, entrega de correo y centralización no quedan implementadas
por mover el código. No borrar el esquema ni cambiar el issuer al adoptar mejoras.

## Ruta de infraestructura y operación

Las fases 1–8 de [la ruta](../ruta-plataforma.md) tienen contratos, módulos y herramientas implementados,
con pruebas locales/protocolo. 9A aporta hosting de referencia Azure administrado y 9B CI/artefactos.
Eso **no acredita el cierre real de 9C**, que cubre frontend, backend, identidad y su recorrido integrado.
9D y fase 10 siguen pendientes; no confundir una suite local con una promoción real.

La referencia ya tuvo preparación/recursos parciales en Azure durante el trabajo anterior. Su
existencia no acredita aplicaciones operativas. Esta entrega no consulta ni cambia Azure; inventario,
permisos y estado real se contrastan al retomar una tarea autorizada de 9C.

Restricciones persistentes para esa referencia:

- Únicamente `dev`; no recrear staging/preprod/prod. Los selectores de la plantilla no autorizan
  ambientes para un producto. Suscripción/destino pertenecen a la definición del producto, no a esta
  plantilla ni a la sesión activa de un operador.
- Pendientes: adopción de la composición Auth/base única, diagnóstico federado/permisos, Keycloak,
  selección de candidatos inmutables, despliegue frontend/backend y aceptación/retirada con evidencia.
- No iniciar estos pasos por una orden genérica de continuar la fábrica o leer el contexto. Se
  mantiene la pausa hasta una instrucción que retome expresamente ese alcance.

## Para actualizar este estado

Registrar fecha, revisiones y enlaces concretos. Un resultado antiguo en verde no valida un HEAD
nuevo ni el estado actual de un servicio cloud. Mantener como pendiente lo no probado y pasar al
historial únicamente lo integrado, conservando la evidencia. Ver [protocolo de relevo](trabajo-entre-agentes.md).
