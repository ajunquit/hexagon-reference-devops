# Ciclo efímero Azure con Genesis y Apocalypse

Este bloque de 9C conecta el [motor](motor-ciclo-ambiente.md) y su
[adaptador Azure](adaptador-ciclo-azure.md) con dos entradas manuales de GitHub Actions:

- **Genesis (Create Infrastructure)**: `genesis.yml`, modos Prepare/Apply/Sync.
- **Apocalypse (Destroy Infrastructure)**: `apocalypse.yml`, modos Quiesce/Prepare/Apply/Sync.

Ambos seleccionan ambiente, instancia y root. Cubren infraestructura de hosting web/backend y
mensajería, siguiendo el grafo y con un plan revisado por etapa. La publicación de imágenes/SPA,
migraciones, activación y recorrido integral se conectarán en el siguiente bloque de 9C.
`applicationVerified` permanece false. Las pruebas de esta entrega no han usado una cuenta Azure.
La decisión y sus límites están en el [ADR 0017](adr/0017-reservas-efimeras-y-workflows-del-ciclo.md).
La primera composición exige web y backend, como los exportadores de hosting de 9A; otras
combinaciones de componentes requieren extender esa referencia antes de habilitarlas aquí.

## Reserva aislada antes de desplegar

La identidad persistente de dev no puede crear grupos, administrar identidades en el bootstrap ni
concederse acceso a un contenedor nuevo. Por eso la **reserva efímera** se prepara con el operador
del bootstrap, usando su autenticación y permisos explícitos. Los workflows de workloads nunca
reciben esos privilegios.

`terraform/bootstrap/azure-ephemeral` administra, en un estado remoto independiente:

- grupos `rg-producto-ambiente-run-ID-attempt-hosting/messaging`, con tag instance;
- una identidad `id-producto-ambiente-run-ID-attempt-deploy`, conservada en el grupo de estado;
- contenedor privado `tfstate-run-ID-attempt-ambiente`, distinto de todos los persistentes;
- federación OIDC exacta al Environment `ambiente-run-ID-attempt` del repositorio;
- Contributor y delegación RBAC condicionada únicamente en los grupos de esa instancia;
- acceso Blob únicamente a su contenedor, sin acceso al contenedor del bootstrap.

Los módulos de hosting y Service Bus declaran principal_type ServicePrincipal en cada asignación
de rol de workloads/operadores. Es necesario para autorizar las solicitudes bajo la condición ABAC
del bootstrap; no se amplía la lista de roles delegables. Fija un commit IaC que incluya este ajuste.
Los operadores de mensajería también usan identidades de servicio separadas. Véase la
[documentación del proveedor](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment.html).

Grupos, identidad y contenedor llevan protecciones de conservación; Apocalypse no los administra.
El operador conserva también el estado de la reserva en
`bootstrap/ephemeral/producto/ambiente/instancia.tfstate`, dentro del contenedor del bootstrap.
La retirada administrativa de reservas ya vacías será una operación de plataforma separada;
este bloque no elimina estados/evidencia ni retira prevent_destroy para forzarla.

El ID identifica una **reserva**, no el despacho de Genesis actual. Usa un ID run-ID-attempt de la
ejecución que originó la reserva y consérvalo durante todos sus despachos de creación, reparación
y baja. Así un reintento no crea otra identidad ni cae en el ambiente persistente. Tras retirar
todos los roots, Genesis rechaza resucitar la instancia; una prueba nueva recibe otra reserva.

## Definición y preparación

`EphemeralEnvironment` v1 contiene un inventario inicial, región, prefijo OIDC, contenedor de
bootstrap, expiración Unix UTC, IDs de revisores y grupos protegidos para probar denegación.
El [ejemplo](../examples/ephemeral-environment.json) es ficticio: hay que sustituir cuentas,
repositorio, commit, hashes, grupos e IDs, y ajustar expiresAt. Su fecha lejana no es un TTL
operativo válido. La creación acepta una expiración futura de **hasta siete días**; una instancia
caducada sigue admitiendo Apocalypse y recuperación. El TTL no apaga ni borra recursos ni sustituye
la limpieza; no presupuestes su costo como si existiera un recolector automático.

Los grupos protegidos incluyen el del estado y al menos un grupo persistente real de cada ambiente
dev/staging/prod. El diagnóstico exige 403; 404, 401 o timeout no acreditan aislamiento. El bootstrap
persistente debe estar preparado antes, con el Storage, contenedores y grupos declarados.
El operador contrasta la existencia/propiedad de esos grupos y la protección del Storage antes de
escribir: claves compartidas deshabilitadas, TLS, cifrado, versionado y retención. Terraform usa el
ID ARM conocido de la cuenta; no consulta ni guarda sus claves para reservar un contenedor.

Desde main actualizado de la instancia DevOps, con Azure CLI del operador y GitHub CLI autorizado
a administrar Environments, prepara una copia de la definición bajo artifacts/ y ejecuta:

```powershell
pwsh ./scripts/Invoke-EphemeralBootstrap.ps1 -Mode Prepare `
  -Definition ./artifacts/reservation-definition.json -Workspace ./artifacts/reservation-review

# Revisar los archivos privados reservation.tfplan y reservation.json antes de continuar.
pwsh ./scripts/Invoke-EphemeralBootstrap.ps1 -Mode Apply `
  -Definition ./artifacts/reservation-definition.json -Workspace ./artifacts/reservation-review `
  -ReviewSha256 <hash-devuelto-por-Prepare>

pwsh ./scripts/Invoke-EphemeralBootstrap.ps1 -Mode GitHub `
  -Definition ./artifacts/reservation-definition.json -Workspace ./artifacts/reservation-review `
  -ReviewSha256 <mismo-hash>

pwsh ./scripts/Invoke-EphemeralBootstrap.ps1 -Mode Verify `
  -Definition ./artifacts/reservation-definition.json -Workspace ./artifacts/reservation-review `
  -ReviewSha256 <mismo-hash>
```

El clientId inicial es provisional; Apply obtiene el real desde Terraform y escribe
`resolved-definition.json`. Conserva la definición original y el mismo workspace durante los
cuatro pasos: su hash está ligado al plan. GitHub/Verify también usan los outputs del estado remoto.
Verify devuelve PreparedForDiagnostic; la acreditación real del aislamiento ocurre después,
autenticando la identidad en el workflow. No presenta un estado local como diagnóstico federado.

La revisión vence en 24 horas y fija definición, código de main, archivos/backend, plan y versión
Terraform. Solo acepta create/no-op, sin imports, cambios destructivos ni acciones diferidas.
Un segundo Prepare en otro workspace lee el mismo estado y permite un plan sin cambios. Un cambio
de código/inputs o un fallo parcial requiere preparar/revisar un plan nuevo; no se repite el binario
anterior. El workspace es privado y debe conservarse para recuperar una reserva parcialmente creada.

GitHub configura las tres variables Azure, restringe a la rama main y rechaza políticas de ramas
adicionales o respuestas incompletas. Si reviewerIds contiene usuarios, exige su revisión sin
autoaprobación ni bypass administrativo. La cuenta/plan GitHub debe admitir esas protecciones;
un rechazo de la API bloquea el proceso, sin debilitarlas. Con la lista vacía, la revisión es la
operación explícita Prepare → revisión privada → Apply; no se afirma aprobación por otra persona.

Después incorpora mediante PR la definición resuelta en la ruta fija:

```text
.config/environments/dev/run-12345-1/
  definition.json
  descriptor.json
  release.json
  inputs/
    hosting.tfvars.json
    messaging.tfvars.json
```

Descriptor/release deben tener los hashes del inventario y proceder de las fuentes inmutables de
9B. Genera los inputs con los exportadores de hosting y Service Bus existentes, y conserva sus
bytes públicos en los nombres anteriores, sin secretos. El hosting inicial mantiene
application_rollout_enabled y maintenance_jobs_enabled desactivados. Los IDs provisionales de
mensajería se reemplazan automáticamente desde las identidades verificadas de hosting antes de
planificar ese root. Las políticas físicas, filtros, DLQ y nombres no se cambian al enlazar IDs.

El token HEXAGON_APPLICATIONS_READ_TOKEN, cuando los repositorios son privados, solo se utiliza
para validar fuentes de aplicación en el primer Genesis. La autenticación cloud usa OIDC; el token
de GitHub para revisar protecciones es independiente. Apocalypse no necesita las fuentes o CI de
las aplicaciones, ni los archivos descriptor/release/inputs: recupera inventario y snapshot de Blob.
El workflow valida protecciones con permisos de lectura y contrasta los bindings mediante su
contexto vars, antes de autenticarse; no recibe permisos administrativos para listar/modificar variables.

## Secuencia de creación y baja

Obtén el SHA-256 de definition.json **ya fusionado en main**. Ambos workflows verifican el archivo
contra Git y exigen ese hash. Comparten exclusión por repositorio/ambiente con cancel-in-progress
false, además del lease/CAS y locking del motor. Las acciones están fijadas por commit, el checkout
incluye historial y los parámetros se pasan por variables de entorno/argumentos seguros.

| Workflow | Modo/root | Resultado |
| --- | --- | --- |
| Genesis | Prepare hosting | Verifica fuentes, crea snapshot/inventario duraderos y guarda el plan |
| Genesis | Apply hosting | Aplica el hash revisado, observa recursos y verifica el root |
| Genesis | Prepare messaging | Recupera hosting, contrasta principal IDs con ARM, enlaza inputs y prepara otro plan |
| Genesis | Apply messaging | Aplica el segundo plan revisado, con hosting Verified |
| Apocalypse | Quiesce hosting | Invalida planes y detiene actividad propia de todos los roots |
| Apocalypse | Prepare/Apply messaging | Retira primero topología/permisos propios de mensajería |
| Apocalypse | Prepare/Apply hosting | Retira hosting y dependencias, después de messaging Destroyed |

Cada Prepare y Apply es un **despacho separado**. No hay apply automático tras preparar. El resumen
del job muestra el reviewSha256 y metadatos, nunca el contenido del plan. Revisa el JSON/binario
privado en el contenedor de instancia antes de usar ese hash. Un operador autorizado puede descargar
el blob de `producto/ambiente/instancia/plans/hash/root.json` a un directorio privado con Azure CLI
(`az storage blob download --auth-mode login ... --file <archivo-privado> --output none`). No lo
copies a logs, PR ni artifacts públicos. Los planes pueden incluir valores sensibles del proveedor.

Apply requiere `CREATE/DESTROY producto ambiente instancia`; Quiesce requiere
`QUIESCE producto ambiente instancia`. El Environment y sus revisores se evalúan en cada despacho;
la aprobación de Apply sucede después de que el plan exista. El hash no sustituye revisarlo.

Quiesce solo admite DeleteEphemeral fuera de prod. Reúne y valida los recursos inventariados antes
de mutar: desactiva revisiones Container Apps, detiene ejecuciones de jobs Manual y deshabilita
topics/suscripciones propios. Rechaza recursos no registrados y jobs programados/de eventos, que
necesitan una coordinación distinta. Espera hasta 90 segundos a la quiescencia observada y conserva
evidencia. No borra mensajes, estado, inbox ni datos por un comando auxiliar; Terraform realiza la baja.
La espera de ausencia posterior a Destroy también es acotada; acceso denegado nunca es ausencia.

## Recuperación y alcance pendiente

Ante un runner interrumpido, usa Sync para el root y luego Prepare/revisión/Apply. Prepare bloquea
un estado Applying/Destroying hasta reconciliarlo; ante un fallo parcial conocido registra primero
las observaciones actuales para poder planificar su retirada. Una pérdida de lease conserva el
inventario y requiere el procedimiento del [adaptador](adaptador-ciclo-azure.md#fallos-recuperación-y-baja).
No se rompe automáticamente. Los jobs dejan un resumen de recuperación incluso si fallan.
Si falla Quiesce, corrige el bloqueo y repite esa operación: vuelve a observar el estado actual,
conserva lo ya detenido y no reactiva recursos como compensación.

La reserva y los workflows están implementados con pruebas de Terraform y dobles explícitos de
GitHub, HTTP Azure y ejecución cloud. La validación real usa la identidad de instancia y exige
acceso positivo propio/negativo protegido antes de ejecutar una etapa. Sin definición real en main,
los workflows se bloquean; no usan los ejemplos como fallback. Prod aparece en el selector pero
se rechaza antes de autenticar: BackupRequired y promoción persistente corresponden a 9D.

Pendiente para cerrar 9C: entrega de artefactos inmutables, migraciones, activación, bindings,
publicación/validación de SPA, recorrido navegador → API/Worker, presupuesto operativo, limpieza
automática del recorrido incluso tras fallos y ejecución completa en una cuenta autorizada.
El ciclo manual y su inventario serán la base de esa limpieza; no se dará por probada por mocks.

Referencias: [OIDC Azure en GitHub](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-azure),
[protecciones de Environments](https://docs.github.com/en/rest/deployments/environments),
[desactivar revisiones](https://learn.microsoft.com/en-us/cli/azure/containerapp/revision),
[detener jobs](https://learn.microsoft.com/en-us/cli/azure/containerapp/job).
