# Preparación de Auth UMA

DevOps prepara realm, clientes OIDC y delegación administrativa. Keycloak conserva roles,
asignaciones, recursos, scopes y políticas de acceso del producto. El backend únicamente los
administra mediante su adaptador y recibe sus referencias; el runtime no prepara el realm.
Una API y su mantenimiento usan una identidad Keycloak acotada al producto y ambiente. El
token de bootstrap pertenece al operador y nunca llega a la API ni a la SPA.

## Configuración y comando

Partir de [la definición ficticia](../examples/keycloak-authorization.json), validada por
`keycloak-authorization-v1`. Declara producto, ambiente, issuer exacto, UUID/clientId del resource
server, scope del API, cliente SPA y orígenes permitidos. Es configuración física de DevOps;
no es un archivo local de políticas que deba evaluar el backend. El UUID de un cliente existente,
el issuer y sus usuarios se conservan. `master` no puede ser el realm del producto.

```powershell
pwsh ./scripts/Invoke-KeycloakAuthorization.ps1 -Configuration <config.json> -Mode Validate
pwsh ./scripts/Invoke-KeycloakAuthorization.ps1 -Configuration <config.json> -Mode Apply -WhatIf
pwsh ./scripts/Invoke-KeycloakAuthorization.ps1 -Configuration <config.json> -Mode Plan
pwsh ./scripts/Invoke-KeycloakAuthorization.ps1 -Configuration <config.json> -Mode Apply
pwsh ./scripts/Invoke-KeycloakAuthorization.ps1 -Configuration <config.json> -Mode Verify
```

Validate y WhatIf funcionan sin plataforma ni credenciales. Plan sólo lee. Las operaciones online
reciben `HEXAGON_KEYCLOAK_BOOTSTRAP_TOKEN`, temporal, obtenido por el operador sin registrarlo en
archivos/consola. Apply/Verify reciben además `HEXAGON_AUTHORIZATION_CLIENT_SECRET`, cargado desde
el gestor de secretos. Para un cliente existente se contrasta la credencial: una diferencia detiene
la preparación y requiere una rotación explícita, no una sustitución silenciosa. No pegar valores
en el JSON, comandos, GitHub, documentación o PR.

El procedimiento está probado con Keycloak 26.6 y FGAP v2. Verifica versión/destino, identidad,
UUID y scopes antes de escribir. Admite issuer directo de Azure y el prefijo `/auth` de AWS.
Las llamadas no siguen redirects y los errores no imprimen cuerpos ni tokens. Una respuesta
ambigua detiene la etapa; otra ejecución consulta lo existente y converge, sin duplicar clientes.

El cliente SPA es público, Code/PKCE S256, redirects/orígenes explícitos y audiencia del API.
Los scopes obligatorios se vinculan por la API de asignación, incluido `basic` para conservar `sub`.
Si el realm los asignaba como opcionales, se retira esa asociación antes de hacerlos predeterminados.
No basta con actualizar una propiedad `defaultClientScopes` del cliente.

La cuenta delegada sólo recibe `query-clients`/`query-users` y FGAP: view/manage/map-roles sobre su
resource server; view/map-roles sobre usuarios. Grupos, administración general y roles administrativos
inesperados bloquean la preparación. Verify contrasta audiencia, PKCE, scopes y las relaciones reales
entre permisos, recursos, scopes y política de usuario. No sobrescribe políticas del resource server
del producto, sus roles ni asignaciones de runtime.

**Conservar la identidad delegada existente.** Los permisos FGAP sobre el mismo recurso se combinan
exigiendo que todos permitan la operación. Crear otra identidad con permisos superpuestos podría
impedir el acceso de ambas. El preflight rechaza una delegación competidora o una política compleja
que no pueda comprobar; no cambia la estrategia global ni elimina permisos para sortearlo. Una
migración de identidad requiere diseño y mantenimiento explícitos. La preparación local sobre AppHost
usa su cliente/secret existentes. [Reglas oficiales de evaluación](https://www.keycloak.org/docs/latest/server_admin/index.html#_fine_grained_permissions).

## Bindings y entrega

El resultado público contiene issuer/audiencia/scope y estos tres ajustes del API:

| Variable | Valor |
| --- | --- |
| `Auth__Authorization__Product` | Producto del descriptor. |
| `Auth__Authorization__ResourceServerId` | UUID conservado del cliente API. |
| `Auth__Authorization__ClientId` | Identidad delegada de ese producto y ambiente. |

`Auth__Authorization__ClientSecret` va exclusivamente en `workloads.<api>.secret_references`:
Key Vault con URI versionada y vault en Azure; ARN del secreto propio del ambiente en Secrets Manager
en AWS. El valor nunca pasa por Terraform. El operador carga en Keycloak la misma credencial que
referencia el workload; este comando no publica secretos ni despliega recursos cloud.

Los contratos backend nuevos declaran `identity.authorization = "keycloak-uma"`. La exportación
rechaza requisitos sin bindings. Los descriptores anteriores siguen válidos para la adopción gradual;
cuando se configura autorización, se exigen exactamente los tres ajustes y el secreto, sólo en la API.
No entregar credenciales IAM a Workers. El frontend conserva únicamente configuración pública OIDC.

Orden: infraestructura/identidad → preparación del realm → Migrations → DatabaseAccess →
**Authorization** → PrepareActivation/ApplyActivation. Authorization usa la imagen inmutable del API:
`--migrate-only --reconcile-auth-authorization --provision-auth-authorization`, conexión de
mantenimiento e identidad Keycloak delegada. Su journal debe estar Succeeded antes del rollout.
La API runtime conserva su usuario SQL restringido. La importación inicial y su reversión siguen la
guía backend; ante una operación pendiente se concilia sin repetir escrituras HTTP del usuario.

La aceptación conserva PrepareAcceptance/Acceptance y el consentimiento existente. Tras
`acceptance-seed`, el job independiente `acceptance-authorization` prepara exclusivamente los
tenants ficticios antes del navegador. Ambos jobs y sus intentos están registrados por separado;
no se reutiliza como evidencia una ejecución anterior a crear esos tenants. No se añade un Worker.

## Validación local

`Test-Repository.ps1` incluye configuración inválida, WhatIf sin plataforma, bindings, orden,
manipulación de templates/referencias y Terraform con mocks. No acredita una ejecución cloud.
Contra un Keycloak local desechable, con el token del operador sólo en el entorno:

```powershell
pwsh ./tests/Invoke-KeycloakAuthorizationAcceptance.ps1 -Origin https://localhost:18188
```

Crea un realm con nombre aleatorio y lo retira al terminar. Comprueba estado vacío, repetición,
scopes opcionales importados, preservación de recursos/políticas, rechazo de una identidad competidora,
secreto incorrecto y denegación sobre otro cliente/realm. No acepta un destino ajeno a loopback.

Para demostrar además que el backend usa la identidad preparada, compilar Release y el bundle
Angular, arrancar AppHost con volumen nuevo y mensajería local desde DevOps si es ML. Preparar una
definición `environment=local` con issuer/UUID del AppHost, su **mismo** cliente delegado y secreto,
cliente SPA y origen `http://localhost:4200`. Inyectar `HEXAGON_AUTH_LOCAL_DATABASE_CONNECTION`
con host loopback y login `hexagon_runtime`; declarar la base desechable con
`HEXAGON_AUTH_LOCAL_DATABASE_EPHEMERAL=true`. No compartir esa conexión en el chat o un archivo.

```powershell
pwsh ./tests/Invoke-AuthLocalIntegration.ps1 -Backend <backend> -Frontend <frontend> -Configuration <local.json>
```

El runner arranca una API Production con SQL restringido y los bindings preparados, sin heredar
credenciales GitHub/cloud/bootstrap, sirve el bundle local y prueba rol, invitación, aceptación,
lectura y revocación con el bearer original. Reaplica la preparación después de las modificaciones.
Retira su proceso propio al terminar. El AppHost y su volumen se retiran expresamente después;
no se borra un volumen ajeno ni una base de producto para ejecutar estas pruebas. Las credenciales
ficticias del navegador pueden llegar por las variables `AUTH_BROWSER_OWNER[_PASSWORD]`.

Las pausas cloud vigentes no cambian por integrar estos scripts ni por disponer de un selector.
