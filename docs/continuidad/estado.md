# Estado verificable para el siguiente relevo

**Fecha de corte: 2026-11-12.** Comprobar GitHub antes de actuar: un PR puede fusionarse o cambiar
después de esta fotografía. Este archivo distingue código, validación local, CI y operación real.

## Trabajo activo: F-01 sincronización asistida

C-01 y C-02 están integrados, comprobado en GitHub: Factory #1, ML #43/#44, MX #3/#4, NG #70,
Vision #20, Core #27, Business #2 y DevOps #29 fusionados. La entrega activa es **F-01**. La
validación Azure 9C sigue **pausada por orden del dueño**.

| Repositorio / PR | Cambio | Estado al corte |
| --- | --- | --- |
| [Factory #2](https://github.com/ajunquit/hexagon-product-factory/pull/2) | `product sync plan/apply/status/publish`: render de base y catálogo, fusión a tres vías, rutas protegidas, conflictos, checks y PR borrador. | Abierto, sin fusionar. Build, 77 pruebas, formato y ejemplos aprobados; recorrido real local con plantillas reales (ver evidencia). |
| [ML #45](https://github.com/ajunquit/hexagon-template-dotnet-ml/pull/45) | README/guía remiten a `product sync`; recorrido manual para productos sin procedencia. | Abierto; solo documentación. |
| [MX #5](https://github.com/ajunquit/hexagon-template-dotnet-mx/pull/5) | Guía de creación enlaza la sincronización. | Abierto; solo documentación. |
| [NG #71](https://github.com/ajunquit/hexagon-template-ng/pull/71) | README y ruta de la fábrica: paso 5 en PR, paso 6 pendiente. | Abierto; solo documentación. |
| [Business #3](https://github.com/ajunquit/hexagon-template-business/pull/3) | Guía de actualizaciones con la fábrica y estado real del coordinador. | Abierto; solo documentación. |
| [DevOps #30](https://github.com/ajunquit/hexagon-template-devops/pull/30) | Checkpoint y pendientes de F-01. | Abierto; solo documentación. |

No fusionar automáticamente. Integrar primero Factory #2; los demás enlazan su guía en `main`.
Actualizar este checkpoint cuando se confirme la integración.

### Evidencia de F-01

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
- Próximo paso: revisar e integrar Factory #2 y luego sus PR de documentación. Después, F-04
  (catálogo) solo si el dueño lo prioriza.

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
