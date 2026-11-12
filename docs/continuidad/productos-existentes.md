# Productos existentes: HR y reference

Estudio del 2026-11-12. Este documento describe cómo llevar a la fábrica los productos creados antes
de ella. **No autoriza** ninguna de las acciones: cada fase requiere una orden del dueño, y las
decisiones abiertas están al final. Comprobar ramas y PR en GitHub antes de actuar.

## Por qué son un caso distinto

`product sync` solo admite productos con `.hexagon/factory-origin.json` y su lock canónico en
business. `product create` crea los cuatro repositorios desde cero y rechaza destinos existentes.
HR y reference nacieron antes de la fábrica, así que no tienen procedencia. Para ellos no sirve
ninguno de los dos comandos sin un paso de adopción.

## HR

HR es un producto **real**. La visión de negocio vive en su ficha de Vision; las decisiones técnicas,
en `adr/` del propio repositorio.

| Componente | Repositorio | Estado al 2026-11-12 |
| --- | --- | --- |
| Frontend | [hexagon-hr-ng](https://github.com/ajunquit/hexagon-hr-ng) (privado) | Existe. Trabaja en `dev`; ramas y PR a `dev`. `main` sigue en el commit inicial del 2026-03-07, 288 commits por detrás. |
| Business | [hexagon-hr-business](https://github.com/ajunquit/hexagon-hr-business) (privado) | Creado el 2026-11-12 desde `hexagon-template-business@1beb350`, con historia y remoto `template`. Inicialización en [#1](https://github.com/ajunquit/hexagon-hr-business/pull/1). El conocimiento sigue en Vision y en el frontend hasta H2. |
| Backend | `hexagon-hr-dotnet-ml` | No existe. El frontend usa la API simulada (ADR 0005). |
| DevOps | `hexagon-hr-devops` | No existe. Las carpetas locales `hexagon-hr/backend` y `devops` están vacías: no acreditan nada. |

### Cómo se actualiza hoy el frontend

El checkout tiene dos remotos: `origin` (el producto) y `template` (`hexagon-template-ng`). Cada
actualización sigue el recorrido manual del README de la plantilla:

```bash
git fetch template
git switch -c chore/update-template-<n> origin/dev
git merge template/main
```

- Commits "base al día con hexagon-template-ng#NN" y PR a `dev`. Hay unos 15 desde octubre; la última
  base integrada es la #59 (`b3a8567`), en HR #49 del 2026-11-08.
- README, AGENTS (con el glosario) y CHANGELOG son del producto. La demo de la plantilla se eliminó
  con `git rm` y "no vuelve". La base (`core/`, `shared/`, `scripts/`, `docs/`) debe quedar idéntica a
  la plantilla.
- A veces se fusionaron ramas `template/fix/*` antes de su merge en la plantilla. Eso complica
  reconstruir la base exacta: la base fiable es el último `template/main` integrado.

### Lo que le falta del frontend

Doce PR de la plantilla (#60–#71, 29 commits, unos 67 archivos):

- Identidad OIDC: `core/auth`, configuración de auth en runtime, interceptor bearer y URL de API por
  tenant, junto con cambios en el login.
- Un **ejemplo Sales** nuevo (clientes) con su i18n.
- Las ADR 0036–0040 y las guías de la fábrica y de la sincronización.

Diez archivos cambiaron en ambos lados y darán conflicto: README, AGENTS, CHANGELOG,
`package.json`/`package-lock.json`, `app.routes.ts`, la plantilla del login, `en.json`/`es.json` y
`.hexagon/frontend-hosting-requirements.json`.

### Ruta recomendada

| Fase | Qué | Condición |
| --- | --- | --- |
| H0 | **Cerrada el 2026-11-12** con [HR #50](https://github.com/ajunquit/hexagon-hr-ng/pull/50): base hexagon-template-ng #60–#72 en `dev`. No entraron el ejemplo Sales ni su manifiesto de aceptación. OIDC está en `core/auth` sin activar: `runtime-config.json` no declara `authentication`, y el manifiesto de hosting v2 ya declara el binding que DevOps proveerá en H4. Se añadió el CI de la plantilla, que corre también en `dev`. | Hecha. Las siguientes actualizaciones siguen igual (`git merge template/main`, PR a `dev`) hasta H1. |
| H1 (F-05) | **Adopción en la fábrica.** Una capacidad nueva crea los componentes que faltan (business, dotnet-ml, DevOps) con su lock. Al componente existente le añade, por PR a `dev`, `factory-origin.json` y `template-sync.json` con una base verificada (el último `template/main` integrado, comprobado como ancestro de `dev`), sin regenerarlo ni sobrescribirlo. Desde ahí, `product sync` sirve también para HR, con base `dev`. | Necesita su diseño y pruebas en la fábrica; el nombre `hr` deriva justo `hexagon-hr-ng`. |
| H2 | Business: migrar el conocimiento de producto de Vision, `ROADMAP.md`, `normativa/` y el glosario, según el [inventario](hr-conocimiento.md). Son tres PR coordinados (business, frontend, Vision), sin inventar requisitos. | Requiere `hexagon-hr-business` (H1). Criterio y destinos ya decididos. |
| H3 | Backend: módulos de HR en `hexagon-hr-dotnet-ml` con **AWS SNS/SQS**, sustituyendo la API simulada pantalla a pantalla y activando entonces OIDC en el frontend. | Primer módulo por decidir. |
| H4 | DevOps y despliegue: solo `dev`, y solo después de que la referencia complete 9C. | Depende de D-9C. |

No regenerar ni sobrescribir `hexagon-hr-ng`. No crear `hexagon-hr-*` sin la orden de H1 ni copiar
estrategia de Vision a la plantilla.

### Decisiones que necesita el dueño

1. Resuelta (2026-11-12): el ejemplo Sales no entra en HR.
2. Resuelta (2026-11-12): OIDC queda inactivo en HR hasta que exista su backend con Keycloak.
3. Resuelta (2026-11-12): el backend de HR usará **AWS SNS/SQS**.
4. Resuelta (2026-11-12): el conocimiento de producto pasa a `hexagon-hr-business` y lo corporativo se
   queda en Vision, según el [inventario de conocimiento de HR](hr-conocimiento.md). El dueño aprueba
   cada PR de migración.
5. ¿Se pone al día `main` de HR con `dev`, o `dev` sigue siendo la rama de trabajo y `main` se
   reserva para releases?

## F-07: sincronización coherente con `template/main`

Decisión del dueño (2026-11-12): **todos los productos conservan el remoto `template` y la historia
compartida con su plantilla**, también los creados por la fábrica, que ya los conservan al
generarse. Sirve para inspeccionar la base (`git diff template/main -- <ruta>`), traer un arreglo
urgente y actualizar productos sin procedencia, como HR.

Hoy los dos mecanismos no se reconocen entre sí:

- El commit de `product sync` tiene un solo padre. Un `git merge template/main` posterior parte de la
  base antigua y vuelve a fusionar cambios que ya están.
- Una fusión manual no actualiza `.hexagon/template-sync.json`, y la siguiente sincronización parte de
  una base atrasada.

Implementación pendiente en la fábrica:

1. El commit de sincronización tiene dos padres: la rama base del producto y el commit de plantilla
   integrado (`targetCommit`). El árbol es el resultado de la fusión a tres vías y de la resolución
   revisada; el segundo padre solo registra la integración para Git.
2. `plan` calcula la base como la más reciente entre `template-sync.json` y el último commit de la
   plantilla que sea ancestro del producto. Así detecta fusiones manuales posteriores.
3. Las publicaciones siguen sin `force` y sin reescribir historia. El PR muestra el merge como
   cualquier otra integración.
4. Pruebas con Git real en los tres escenarios: sincronizar y luego fusionar a mano; fusionar a mano
   y luego sincronizar; y el backend renombrado.

Un producto avanza su base por un camino principal: `product sync` si tiene procedencia, la fusión
manual mientras no la tenga. El remoto `template` queda como herramienta universal.

## Referencia (`hexagon-reference-*`)

Laboratorio de la plataforma; se desplegará en **Azure**, solo `dev` (decisión del dueño,
2026-11-12). Análisis del mismo día, hecho sobre GitHub y sin consultar Azure (9C sigue pausada):

| Componente | Repositorio | Estado frente a la plantilla |
| --- | --- | --- |
| Business | `hexagon-reference-business` | **No existe.** |
| Frontend | `hexagon-reference-ng` (privado) | Comparte historia; base integrada `76fd4a7` (#65); 21 commits por detrás. Se puede adoptar con F-05 tal como está. |
| Backend | `hexagon-reference-dotnet-ml` (privado), Azure Service Bus | Comparte historia; base `7ae1e54`; 31 commits por detrás. Se puede adoptar con F-05. |
| DevOps | `hexagon-reference-devops` (**público**) | **No comparte historia.** Se creó con `--template`: su commit inicial `d0bfc92` tiene **exactamente** el árbol de `hexagon-template-devops@0c96847`. 98 commits por detrás. |

Ninguno tenía `factory-origin.json`. Hay checkouts locales en `C:/Workspace/hexagon/hexagon-reference/`;
el de DevOps tiene cambios sin confirmar de otra sesión, que no deben tocarse.

**Actualización del 2026-11-12 (R-01):** la tabla anterior es el punto de partida. Hoy los cuatro
componentes tienen procedencia de la fábrica: business creado, y `-ng`, `-dotnet-ml` y `-devops`
adoptados. `-ng` y `-devops` están sincronizados con el catálogo vigente y `-dotnet-ml` lo está en
su PR #6. Ver el [estado](estado.md).

### Completar reference con la fábrica

1. **F-05b (extensión necesaria): adoptar copias sin historia compartida.** Si el commit inicial
   del repositorio tiene el mismo árbol que un commit de la plantilla, la adopción lo usa como base
   verificada. El PR de adopción incluye un merge con estrategia `ours`: no cambia ningún archivo,
   pero establece la historia compartida, de modo que `product sync` y `template/main` funcionan
   después. Sin coincidencia exacta, se sigue rechazando.
2. `product reconcile` de reference (ML con Azure Service Bus, solo `dev`):
   - adopta `-ng`, `-dotnet-ml` y `-devops`, cada uno contra su rama base real;
   - crea `hexagon-reference-business` (privado).
3. `product sync` de cada componente hasta el catálogo vigente: 21, 31 y 98 commits de plantilla.
4. Después, D-9C despliega reference en Azure `dev`, cuando el dueño lo ordene.

El DevOps de reference es **público**, pero los componentes que crea la fábrica son privados. La
adopción no cambia la visibilidad: su PR solo añade procedencia (lock y commits), nunca contenido
privado.

### ¿Cambiar el nombre a `lab1`, `labaz1` o `labazml1`? Recomendación: **no**

El nombre está en recursos que no se pueden renombrar:

- **Azure**:
  - `.config/platform-bootstrap.yaml` declara `rg-hexagon-reference-state`, que guarda el estado
    Terraform, y `rg-hexagon-reference-dev`, `-dev-messaging` y `-dev-auth`;
  - declara también la identidad `id-hexagon-reference-dev-deploy`, cuyas credenciales federadas
    dependen del nombre del repositorio en GitHub;
  - un grupo de recursos de Azure no se renombra: habría que crear otro, migrar el estado y retirar el
    anterior con Apocalypse.
- **GitHub y la fábrica**: tres repositorios y sus descriptores. La fábrica deriva los destinos del
  nombre del producto (`hexagon-<nombre>-<componente>`).
- **Código**: 158 archivos del backend con `Hexagon.Reference.*`, más los recursos de Aspire, Keycloak
  y la base de datos, y la identidad del frontend.

El beneficio es solo de nombre en un laboratorio, y el riesgo es tocar estado e identidad cloud ya
creados. Si se quiere la convención `lab…`, conviene aplicarla al próximo laboratorio. **Pendiente de
decidir por el dueño**; mientras tanto se conserva `reference`.

## HR en AWS

HR se desplegará en **AWS**, solo `dev`. La plantilla DevOps ya tiene bootstrap AWS (estado S3 con KMS
e identidad) y mensajería SNS/SQS, pero **no tiene hosting de aplicaciones en AWS**. Solo existe
`terraform/modules/hosting/azure` y `environments/dev/hosting-azure`: SPA, API/Workers, PostgreSQL y
Keycloak están resueltos únicamente en Azure. Desplegar HR en AWS requiere antes **D-9A-AWS**: el
módulo de hosting AWS con sus contratos, pruebas locales y documentación. Ver pendientes.
