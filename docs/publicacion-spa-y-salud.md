# Publicación de la SPA y verificación de hosting

Este bloque de 9C añade **PublishWeb** y **VerifyServing** a Application Delivery después de
ApplyActivation. Implementa la publicación del candidato web y la comprobación de archivos y salud
de API/Workers. Continúa usando la instancia efímera dev/staging, Environment, OIDC, concurrencia,
inventario y lease de la [entrega del backend](entrega-aplicaciones-azure.md).

No se ha ejecutado una cuenta Azure real. Las pruebas locales y de CI no acreditan el recorrido
completo del producto. Autenticación en navegador, tenant, reacción de mensajería y limpieza
integral automática siguen pendientes; `applicationVerified` permanece false.

## Ejecutar las etapas

1. Completa Artifacts → PrepareMaintenance/ApplyMaintenance → Migrations → DatabaseAccess →
   PrepareActivation/ApplyActivation con los planes revisados y la misma selección inmutable.
2. Despacha Application Delivery en main con **PublishWeb**, seleccionando el ambiente/instancia y
   los mismos hashes de definition.json y delivery.json. No necesita otro plan: publica contenido
   en el sitio que Terraform ya creó, sin modificar recursos ni permisos.
3. Despacha **VerifyServing** con esa selección. Comprueba el contenido público y observa salud
   actual de cada workload; devuelve el hash de evidencia en Blob. Esta etapa no necesita instalar
   el cliente de publicación ni obtener el token del sitio.

La comprobación es acotada: una respuesta obsoleta, un error de CDN, una revisión no lista o una
réplica sin readiness bloquean la etapa. Tras esperar la convergencia se puede repetir VerifyServing.
No se aceptan respuestas parciales o errores de acceso como éxito. La evidencia es una observación
en ese momento, no una garantía permanente de disponibilidad.

## Artefacto y configuración pública

PublishWeb descarga solo el candidato web original por su artifact ID/run/intento/hash de GitHub.
No vuelve a necesitar los candidatos backend/operaciones. Verifica ComponentBuild, checksum del
bundle y manifiestos del release. Lee el contrato frontend y su esquema desde el commit fijado y
contrasta su hash antes de producir configuración.

El bundle de CI se conserva intacto. Una copia privada de despliegue recibe exclusivamente:

- **runtime-config.json:** apiUrl de la API desplegada y cliente OIDC público (authority, clientId,
  scope), seleccionados mediante el contrato existente. No contiene tokens ni outputs arbitrarios.
- **staticwebapp.config.json:** fallback a index.html y políticas de caché/seguridad existentes.
- **hexagon-deployment.json:** marcador público con hashes del release, selección, archivo original,
  overlay y contenido. No contiene identidad Azure, secretos, rutas locales ni configuración privada.

El marcador es determinista. El mismo bundle/overlay/selección genera la misma identidad al volver
a ejecutar, y un bundle que ya contenga ese nombre reservado se rechaza.

## Cliente oficial fijado

`.config/static-web-client.json` fija build, URL y SHA-256 del StaticSitesClient de Microsoft para
Linux/Windows x64. Se tomó el build del 28 de septiembre de 2026 publicado en los
[metadatos oficiales](https://aka.ms/swalocaldeploy), con más de dos semanas de antigüedad.
No se consulta la etiqueta backup, stable ni latest al ejecutar.

El workflow descarga y verifica el binario **antes de Azure login**. Se guarda bajo artifacts y se
revalida el checksum al arrancar; no se confirma en Git. El job de CI también lo descarga y ejecuta
con una acción deliberadamente inválida y sin credenciales: comprueba que el binario arranca y
rechaza esa acción sin publicar contenido. No es una prueba de despliegue real.

Para verificar la instalación local, sin autenticarse:

```powershell
pwsh ./scripts/Install-StaticWebClient.ps1 -WhatIf
pwsh ./scripts/Install-StaticWebClient.ps1
pwsh ./tests/Test-StaticWebClient.ps1
```

Una descarga incompleta o un checksum incorrecto bloquean la instalación. No se usa otra versión
como fallback. Se inspecciona el archivo bajo artifacts antes de retirarlo y repetir la instalación.
Actualizar la herramienta requiere PR con ambos hashes contrastados y CI; no cambia la SPA ni
publica paquetes del core.

El adaptador usa el protocolo de entorno del
[cliente utilizado por SWA CLI](https://github.com/Azure/static-web-apps-cli/blob/v2.1.0/src/cli/commands/deploy/deploy.ts):
upload, proveedor SwaCli, SKIP_APP_BUILD/SKIP_API_BUILD true, API y Data API vacías, directorios
verificados y token en memoria. No incorpora la instalación npm de SWA CLI ni comandos de build.

## Credenciales y alcance

| Acceso | Uso |
| --- | --- |
| OIDC de la instancia | ARM para su infraestructura y token del sitio propio |
| HEXAGON_ARTIFACTS_READ_TOKEN | Actions: read del frontend privado para PublishWeb/VerifyServing; conserva los permisos de Artifacts |
| HEXAGON_APPLICATIONS_READ_TOKEN | Contents: read del frontend privado para su manifiesto y esquema; se conserva el acceso ya usado por Genesis |
| Token de despliegue SWA | Se obtiene de listSecrets del sitio actual y solo se entrega al proceso de publicación |

Para fuentes públicas se puede usar el github.token disponible sin el secreto de Contents. Para
repositorios privados se configura el acceso indicado; no se añade un token SWA estático a GitHub.
La evolución a GitHub App con credenciales temporales de lectura continúa recomendada.

El sitio debe coincidir con el recurso actual del inventario y el hostname observado por ARM. La
identidad no recibe permisos nuevos ni aprovisiona desde runtime. El slot principal de un sitio
efímero se denomina production en las herramientas de SWA; sigue siendo el recurso aislado del
ambiente dev/staging seleccionado, sin actuar sobre el ambiente persistente prod.

El proceso de contenido no hereda tokens GitHub/Azure ni acepta argumentos o variables libres.
Su stdout/stderr se capturan sin publicarlos ni conservarlos como evidencia. Los probes públicos
no envían Authorization/Cookie y no siguen redirecciones a otros destinos. Los planes, snapshots,
logs libres y directorios de despliegue no se suben como artefactos de CI.

## Qué significa Verified en esta etapa

- Todos los archivos públicos esperados coinciden en SHA-256 y tamaño, con MIME compatible para HTML, JS,
  CSS, JSON y WASM. No basta comprobar que index.html responde 200.
- El marcador coincide antes y después de comprobar archivos. runtime-config.json e index.html
  tienen no-store; raíz y ruta profunda obligan a revalidar y sirven el index esperado.
- staticwebapp.config.json es configuración del host, no un asset público que deba responder por
  HTTP. Se valida localmente y se comprueban sus efectos: routing/caché, nosniff y no-referrer.
- Cada API/Worker es un Container App registrado, con su imagen por digest, identidad y bindings
  esperados. El Worker no expone ingress; la API entrega tráfico al puerto 8080 y a la revisión lista.
- La revisión activa es Healthy/Provisioned/Running, con los probes de salud en 8081 y suficientes
  réplicas iniciadas/listas. No se publican las conexiones ni los valores de configuración observados.
- El estado de hosting conserva su ETag durante la observación; la evidencia se guarda por hash
  con lectura posterior antes de confirmar Verified en el journal de entrega.

La [aceptación integral](aceptacion-integral-azure.md) amplía este mecanismo con navegador y
limpieza consentida. Su ejecución Azure real continúa pendiente.

El journal web guarda Publishing antes del cliente y Published tras exit code 0. VerifyServing es
una comprobación separada; puede reconciliar Publishing si el servidor ya entrega exactamente el
contenido esperado. Al reverificar se retira primero el Verified anterior, sin borrar evidencia
histórica. Un fallo conserva inventario, selección e intención para investigar/repetir.

Apocalypse sigue funcionando sin el candidato web, tokens de aplicaciones ni este journal. La
limpieza integral automática y el recorrido real con navegador/Auth/API/Worker son el siguiente
bloque de 9C; no se sustituyen por estos probes de hosting.
