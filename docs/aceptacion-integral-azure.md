# Aceptación autenticada y limpieza de una instancia efímera

Este bloque de 9C implementa el navegador y la retirada por el motor, según
[ADR 0020](adr/0020-aceptacion-autenticada-y-retirada-efimera-consentida.md). La ejecución contra
Azure real sigue pendiente: los ejemplos no son destinos autorizados.

## Preparación

1. Integra los cambios del core, backend y frontend. El backend consume el core fijado por commit;
   CI lo empaqueta localmente. No hace falta publicar un paquete remoto para este recorrido.
2. Fija `.hexagon/acceptance-requirements.json` de **backend y web** en descriptor y release,
   junto con sus manifiestos de hosting/mensajería y los artefactos de CI/main. El consumidor
   acepta builds anteriores sin ese manifiesto para entrega normal, pero los rechaza para E2E.
   Usa `New-ProductEnvironmentDescriptor.ps1` con `-IncludeBackendHosting -IncludeAcceptance`
   y los pares Repository/Ref de ambos componentes; resuelve commits y hashes, no los copies a mano.
3. La plataforma prepara una cuenta OIDC de prueba exclusiva, sin privilegios globales, su subject
   UUID y el cliente público del ambiente (callbacks, issuer, scope y audiencia correctos). Esta
   referencia conduce el formulario Keycloak normal, sin ROPC ni atajos de autenticación. Otros
   formularios/IdP o MFA interactivo necesitan otro adaptador; no se desactiva una política global.
4. Configura `HEXAGON_E2E_USERNAME` y `HEXAGON_E2E_PASSWORD` como secrets del GitHub Environment
   **de la instancia**. El subject es una referencia pública de composición; no es una credencial.
5. En la política hosting, antes de crear el snapshot y preparar mantenimiento, añade:

   ```json
   "acceptance_fixture": {
     "instanceId": "run-123-1",
     "subjectId": "55555555-5555-4555-8555-555555555555",
     "tenant": "e2e-run-123-1-a",
     "otherTenant": "e2e-run-123-1-b"
   }
   ```

Es una propiedad opcional de `infrastructure`, trasladada a los tfvars de hosting. Terraform
crea `acceptance-seed` cuando se habilita mantenimiento, con la imagen API por digest, identidad
de mantenimiento y cero reintentos de réplica. No crea cuentas OIDC ni incluye su contraseña.
Solo se admiten los dos slugs derivados de la instancia y dev/staging. El backend aplica permisos
exactos `sales.customers.view`/`sales.customers.manage` y falla si encuentra accesos distintos.

Usa una **reserva nueva** fijada al commit IaC que incorpora este job. Añadir la fixture a un
snapshot que ya ejecutó migraciones invalida la evidencia de mantenimiento; no se modifica a
mano su hash/journal. Las reservas anteriores conservan Apocalypse como vía de recuperación.

## Ejecución por Application Delivery

Mantén el Environment, concurrencia, identidad federada y lease de la instancia. Primero completa
Artifacts, mantenimiento, migraciones/permisos, activación, PublishWeb y VerifyServing según la
[guía de entrega](entrega-aplicaciones-azure.md). Después:

| Despacho | Entrada y resultado |
| --- | --- |
| PrepareAcceptance | Usa los mismos hashes de definición/delivery. Revalida contenido y salud; genera `consents/<hash>.json` en el contenedor privado. |
| Acceptance | Exige ese `review_sha256` y `TEST AND CLEANUP <producto> <ambiente> <instancia>`. Ejecuta semilla, navegador, evidencia y retirada. |

Abre el consentimiento por la ruta devuelta en el contenedor de la instancia. Revisa producto,
ambiente, instancia, grupos, todos los IDs/direcciones/tipos, lineage/serial y hashes de contexto.
El consentimiento caduca a las 24 horas y cualquier cambio lo invalida. No autoriza producción,
datos persistentes, recursos futuros ni bootstrap. Nunca se interpreta un nombre de rama como
fuente de despliegue ni se toma un plan desde un PR no confiable.

El navegador entra por la ruta protegida declarada por la SPA, verifica Code/PKCE S256 y conduce
Hexagon Auth. Rellena la pantalla del ejemplo, observa POST 201 con Bearer del subject esperado,
espera la confirmación del Worker y lee de nuevo la confirmación persistida. El mismo usuario
pertenece a ambos tenants: leer ese cliente desde el segundo debe dar 404. No hay API mock en la
SPA de producción ni un endpoint que omita autenticación.

El proceso usa Playwright **1.64.1** y su Chromium, fijados por lockfile. Solo acepta URLs HTTPS
y el perfil conocido. El token se conserva en memoria; no hay almacenamiento de sesión, HAR,
trazas, vídeos o capturas. Los destinos de aplicación/API/issuer están fijados por los outputs
verificados; se bloquean recursos decorativos externos y falla ante destinos funcionales ajenos.
El proceso no hereda tokens GitHub/Azure, NODE_OPTIONS ni variables libres. Sus errores se
reducen a códigos seguros, sin publicar URLs de callback, cuerpos, cookies o excepciones libres.
Referencias: [autenticación](https://playwright.dev/docs/auth) y
[observación de red](https://playwright.dev/docs/network) de Playwright.

## Evidencia y limpieza

El journal registra Testing antes del job y Cleaning antes de retirar recursos. El job conserva
su marcador/intento y usa la reconciliación de mantenimiento existente; no repite un POST ambiguo.
Una segunda ejecución de Acceptance queda bloqueada si ya hay una intención registrada.

El resultado del recorrido se custodia antes de borrar, incluso si falló. Después se detienen
aplicaciones/jobs/broker y se retira messaging antes de hosting. Cada plan nuevo se limita al
conjunto exacto revisado: sin altas, updates, replacements, imports o IDs desconocidos. Se
guardan planes y hashes y se aplica mediante el motor existente, que verifica ausencia real.
El fallo de un root bloquea el siguiente. Se conservan grupos reservados, identidades de
despliegue, bootstrap, estado remoto, inventario y evidencia.

El journal y `acceptance-evidence/v1` separan `journeySucceeded` y `cleanupStatus`; un recorrido
correcto con limpieza fallida termina con error. `Completed` exige ambos resultados. El inventario
conserva `applicationVerified=false`: el ambiente ya retirado no ofrece disponibilidad continua.

Un error al custodiar evidencia impide borrar. Un corte del runner, timeout global o cancelación
forzada puede impedir `finally`; el workflow no promete limpieza en esos casos. Investiga el
journal, espera/libera correctamente la ejecución que mantiene el lease y usa **Apocalypse**
para quiescer, Sync si hubo estado parcial y preparar/aplicar nuevos planes revisados. No
borres inventario, no rompas leases automáticamente ni alteres el inbox para reintentar.

## Pruebas y cierre de 9C

```powershell
npm ci --prefix acceptance --ignore-scripts
node acceptance/node_modules/playwright/cli.js install chromium
pwsh ./scripts/Test-Repository.ps1
```

En Linux puede necesitarse `install --with-deps chromium`. Las pruebas cubren consentimiento,
caducidad, cambios de contexto, acciones/recursos prohibidos, orden real del motor, fallos de
semilla/navegador/retirada y custodia previa. Chromium prueba el adaptador contra endpoints
interceptados **solo en la suite de protocolo**. No se publica esa ejecución como evidencia cloud.

Para cerrar 9C aún hace falta una definición real autorizada, la cuenta de pruebas y ejecutar
el recorrido completo en Azure, conservando sus evidencias y el inventario Destroyed. Luego
corresponde 9D: promoción de los mismos artefactos a ambientes persistentes y operación.
