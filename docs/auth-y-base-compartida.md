# Auth y Keycloak en la base del producto

La [ADR de plataforma 0036](https://github.com/ajunquit/hexagon-template-ng/blob/main/docs/adr/0036-auth-integrado-con-evolucion-a-identidad-central.md)
acepta la modalidad inicial integrada: un módulo Auth en el backend y una sola base PostgreSQL,
con esquemas `platform`, `auth`, `keycloak` y los del negocio. Keycloak sigue siendo otro proceso.
La modalidad centralizada queda como evolución, con una migración explícita.

## Estado y alcance

**Composición implementada; ejecución Azure pendiente.** El AppHost del backend ya prepara una
base local compartida. El módulo `hosting/azure` admite ahora Keycloak en esa misma base, mediante
un perfil opcional limitado a `dev`. La [ADR 0021](adr/0021-keycloak-integrado-en-la-base-del-producto-dev.md)
registra esta composición. La preparación antigua de la referencia con otro servidor de identidad
debe reemplazarse al adoptarla; no se aplica para luego migrarla.

La primera ejecución de 9C usará únicamente `dev` de la referencia aislada. La existencia de roots
o selectores `staging`/`prod` en la plantilla no autoriza crearlos. Las funciones completas del
módulo Auth no son un requisito previo para validar los mecanismos actuales de acceso en 9C.

## Propiedad y orden

- Un único root Terraform es dueño del servidor y de la base. El componente Keycloak recibe sus
  referencias mediante outputs/bindings; no declara otra base ni importa la misma en otro estado.
- DevOps coordina la preparación SQL desde un job de mantenimiento: esquema `keycloak`, usuario
  dedicado y permisos limitados. El backend HTTP no crea infraestructura ni usuarios de base.
- La identidad de mantenimiento del producto, sus identidades runtime y la conexión de Keycloak
  son distintas. La inicialización y actualización de roles no conceden acceso global a esquemas
  nuevos. No se introduce una contraseña administrativa de PostgreSQL en Keycloak.
- Keycloak recibe la base del producto y `KC_DB_SCHEMA=keycloak`. Sus secretos llegan por el gestor
  del proveedor, sin persistirlos en contratos, planes o estado Terraform.
- EF Core conserva las migraciones de los esquemas Hexagon y Keycloak ejecuta las propias. No se
  aplican las reglas RLS/auditoría/outbox/inbox de Hexagon al esquema de Keycloak.
- El grafo declara base → preparación SQL → Keycloak y base → migraciones de aplicación → rollout.
  La configuración del emisor y la disponibilidad de Keycloak se resuelven antes de la aceptación.
  El diseño final debe evitar un ciclo entre crear hosting y conocer el emisor público.
- La retirada detiene consumidores y Keycloak antes de eliminar la base. Una base persistente
  compartida no puede incluirse en la retirada consentida de una instancia efímera.

En una referencia completamente efímera, Keycloak y los datos ficticios pueden compartir el ciclo
de la base solo si el inventario, consentimiento y plan de baja incluyen sus recursos exactos.
Si la identidad se conserva, también se conserva su almacenamiento y cambia el alcance del ciclo.
No se destruye indirectamente una identidad retenida al retirar el root de hosting.

## Configuración del perfil integrado

La política `azure-hosting-policy-v1` conserva `infrastructure.auth.client_id`; establece
`auth.authority=null` y añade `infrastructure.keycloak` con estos campos:

| Campo | Contenido |
| --- | --- |
| `image` | Imagen oficial `quay.io/keycloak/keycloak@sha256:…`, revisada e inmutable. |
| `realm` | Nombre del realm del producto, distinto de `master`. |
| `bootstrap_user` | Usuario administrativo inicial, sin contraseña en la política. |
| `server_password_revision` | Entero positivo; incrementar para aplicar una rotación administrativa. |
| `server_password` | Referencia al secreto administrativo que exige AzureRM al habilitar contraseña. |
| `database_password` | Referencia al secreto del rol SQL dedicado a Keycloak. |
| `bootstrap_password` | Referencia al secreto del administrador de arranque de Keycloak. |

Cada referencia contiene solo `secret_uri` con versión y `vault_resource_id`. Los tres secretos
deben tener nombres distintos, estar preparados antes de Genesis y pertenecer a un vault del grupo de
hosting y de su suscripción. El vault conserva propiedad de bootstrap; no se elimina con el root.
Se requiere el modelo de permisos Azure RBAC. Su acceso de red debe permitir al operador leer el
secreto administrativo y al entorno Container Apps resolver las referencias runtime.

La identidad que ejecuta Terraform necesita lectura acotada del secreto `server_password` antes
de planificar **y aplicar**. AzureRM lo consulta como recurso ephemeral y lo entrega únicamente a
`administrator_password_wo`, con su revisión; el valor no se serializa en plan ni tfstate. Esta
implementación no crea secretos ni los solicita como variables de GitHub. No se reemplaza por
un data source ordinario ni por `TF_VAR_*`. No ejecutar con trazas HTTP/SQL o `TF_LOG` que expongan
credenciales. El flujo necesita Terraform >= 1.11 por los argumentos write-only.

La contraseña SQL de Keycloak debe contener entre 32 y 128 caracteres alfanuméricos generados
aleatoriamente. La administrativa de PostgreSQL debe satisfacer las reglas de Azure. Las tres
credenciales se generan y cargan mediante un procedimiento del operador fuera de Terraform,
sin pegarlas en consola, documentación ni PR. El mantenimiento solo recibe la contraseña SQL
dedicada mediante `secretRef`; Keycloak recibe esa referencia y la del administrador de arranque.
Sus identidades tienen lectura por nombre de secreto, sin lectura del resto del vault.

No establecer una autoridad externa junto al perfil integrado. El módulo deriva el origen ACA
HTTPS y el emisor `/realms/<realm>` sin depender de que Keycloak ya exista, y los entrega a backend
y configuración pública del frontend. El puerto de administración 9000 solo sirve a las sondas;
el ingress público apunta a 8080. Keycloak conecta al PostgreSQL privado con TLS y verificación
del certificado. Se usa una réplica, 0.5 CPU/1 GiB y pool de conexiones pequeño para la referencia.

## Orden de entrega

Los comandos siguen [la guía de entrega](entrega-aplicaciones-azure.md), con los mismos hashes,
lease, Environment y revisión de planes. Los flags no se cambian a mano para saltarse etapas.

1. Exportar los inputs y preparar/aplicar Genesis con ambos rollouts deshabilitados. El servidor,
   base, identidades y bindings existen; aún no hay proceso Keycloak ni aplicaciones.
2. `Artifacts` copia los candidatos inmutables. Usar un candidato **nuevo de operaciones DevOps**
   que contenga `--prepare-keycloak`; no hace falta publicar paquetes del core. El JSON del job
   lleva `purpose=keycloak`: una imagen antigua lo rechaza antes de modificar la base.
3. `PrepareMaintenance` / `ApplyMaintenance` habilitan los jobs mediante plan revisado.
4. `KeycloakDatabase` prepara rol y esquema con la identidad Entra de mantenimiento. Una segunda
   ejecución converge; un intento ambiguo se reconcilia y nunca repite el POST a ciegas. Un rol
   elevado, con membresías o un esquema de otro propietario bloquean la preparación.
5. `PrepareIdentity` / `ApplyIdentity` revisan y aplican exclusivamente la activación del proceso
   Keycloak dentro del root de hosting. No activan el backend.
6. Configurar el realm y el cliente público del producto, redirects, origen web, audiencia y
   permisos coherentes con sus contratos, usando un procedimiento revisado del operador. Este
   PR no automatiza la administración de Keycloak ni implementa el módulo Auth. El bootstrap
   administrativo de Keycloak solo resuelve el acceso inicial; cambiar su secreto no rota por
   sí solo la contraseña de un administrador que ya existe.
7. `Migrations` exige evidencia SQL y valida contra ARM la revisión de Keycloak, su imagen,
   identidad, referencias y sondas, además del descubrimiento OIDC del **realm del producto**
   con emisor exacto y PKCE S256. `master` disponible no satisface esta precondición.
8. `DatabaseAccess` concede acceso runtime a los esquemas Hexagon y comprueba que los roles runtime
   no tengan acceso a `keycloak`. Un permiso inesperado bloquea la transacción; este job no toma
   propiedad del esquema para corregir permisos de identidad.
   Continúan `PrepareActivation` / `ApplyActivation`, `PublishWeb`, `VerifyServing` y aceptación.

Una rotación SQL requiere un mantenimiento planificado: fijar una nueva versión y volver a
preparar con el proceso detenido, actualizar referencias y validar antes de reactivar. No se
promete rotación en caliente; `KeycloakDatabase` rechaza un rollout ya habilitado. No ejecutar
Apocalypse ni cambiar flags para improvisar una rotación sobre datos persistentes.

La implementación usa una membresía temporal de mantenimiento para crear el esquema con el
propietario dedicado y la deja sin herencia ni permiso `SET ROLE`. Esto permite usar un rol con
`CREATEROLE` sin superusuario, según las [reglas de PostgreSQL 17](https://www.postgresql.org/docs/17/role-attributes.html).
La cuenta de Keycloak no recibe esa membresía ni permisos de Hexagon.

## Evidencia y validación pendiente

Las pruebas Terraform usan mocks: comprueban un único servidor/base, el orden de activación,
las referencias sin valores y el rechazo de producción o emisores mixtos. Las pruebas de entrega
simulan ARM y comprueban identidad/revisión, OIDC/PKCE, cambios de imagen, referencias y bloqueo
antes de las migraciones. No acreditan permisos efectivos de una suscripción Azure.

La integración con PostgreSQL 17 y Keycloak reales verifica creación desde base vacía, arranque
y reinicio, repetición de preparación con un mantenedor sin superusuario y denegación entre
`keycloak` y los esquemas de negocio. Se ejecuta con:

```powershell
dotnet test operations/Hexagon.Messaging.Operations.Tests -c Release -warnaserror --filter 'Category=Database'
```

Antes de la ejecución Azure todavía corresponde:

1. Actualizar la referencia desde las plantillas e incorporar sus versiones de secretos,
   configuración de realm/cliente y nuevo candidato DevOps, sin adoptar el servidor separado.
2. Comprobar permisos efectivos Entra/Key Vault y la conectividad privada desde el job y Keycloak.
3. Revisar que el plan real contiene un único servidor y una única base de aplicación, sin otro
   PostgreSQL de identidad, y que el mantenimiento no amplía los permisos runtime.
4. Revisar el alcance exacto `dev`. Ejecutar diagnóstico y ciclo solo después de integrar
   los cambios y conservar la evidencia real de identidad, aplicación y retirada.

Compartir almacenamiento reduce recursos respecto de dos servidores contratados, pero Keycloak
mantiene su consumo de ejecución. Dos bases lógicas en el mismo servidor no equivalen a dos
servidores facturados: la elección de una sola base es también una decisión de simplicidad inicial.
No se promete disponibilidad, escalado o recuperación independiente entre sus esquemas.

La [ruta del módulo backend](https://github.com/ajunquit/hexagon-template-dotnet-ml/blob/main/docs/auth-integrado.md)
define su evolución. La [fase 9](fase-9-entrega-producto.md) conserva la aceptación y promoción; esta
guía no acredita una ejecución cloud ni cambia Terraform como herramienta de IaC.
