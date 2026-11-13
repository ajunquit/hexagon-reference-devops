# Caché y presupuestos de recursos locales

El recorrido local descargaba proveedores para cada root, aunque la CI ya exportaba una caché
por job. `Test-Repository.ps1` comprueba ahora espacio al arrancar y antes de la fase Terraform.
Los init de esa fase usan `scripts/workspace_resources.py` para compartir proveedores y bloquear
inicializaciones concurrentes. Terraform validate/test mantienen su comportamiento anterior.

Requiere Python 3.10+ además de los requisitos existentes. La raíz se determina por WorkspaceRoot,
HEXAGON_WORKSPACE_ROOT o un ancestro con perfil `.tools/workspace-resources.json`/`.worktrees`;
en un runner aislado, se usa el repositorio. No cambia workflows ni aplica infraestructura.

```powershell
python ./scripts/workspace_resources.py configure --workspace-root <raiz-Hexagon>
pwsh ./scripts/Test-Repository.ps1 -WorkspaceRoot <raiz-Hexagon>
```

La configuración es por usuario: caché fuera de worktrees y entrada persistente en Terraform CLI,
perfil local y helper estable en la raíz. Conserva ajustes existentes; un conflicto se detiene para
revisión. Valores iniciales: 50 GiB temporales y 15 GiB de caché; se configuran mediante configure
--workspace-gib y --cache-gib. No se elevan automáticamente ni se borra estado para liberar espacio.

El check cuenta archivos con hardlinks una sola vez. Si el workspace temporal ya supera su límite,
se bloquea la nueva validación hasta limpiar candidatos verificados. El guard no es una cuota de
sistema de archivos: una descarga puede cruzar el límite antes de la comprobación posterior.

Durante init se usa un lock por caché. Terraform conserva sus verificaciones del lockfile. Si
Windows copió los archivos, el helper compara contenido y crea hardlinks, verificando identidad
física. Si no puede compartir, detiene la operación con los archivos locales intactos. No se usa
plugin_cache_may_break_dependency_lock_file. Los init ajenos al helper no participan en su lock.

npm y NuGet ya mantienen cachés globales. Las instalaciones node_modules de versiones distintas no
se comparten a ciegas; sus directorios y compilaciones están sujetos al presupuesto temporal.
Al finalizar, auditar y retirar worktrees terminados con la skill, preservando trabajo pendiente.
Los datos personales, secretos, estados, respaldos y evidencias se revisan, no se asumen basura.

El helper y sus pruebas proceden de hexagon-ai-tools; ver el manifiesto scripts/workspace-resources-source.json.
Se distribuye una copia fijada para que DevOps y productos no dependan de descargar ese repo privado
en runtime o CI. Al actualizar, verificar origen, hash y pruebas. No hay paquetes nuevos publicados.

[Documentación oficial de la caché](https://developer.hashicorp.com/terraform/cli/config/config-file#provider-plugin-cache).
