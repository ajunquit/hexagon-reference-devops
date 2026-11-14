# Acceso de la cuenta AWS

Bootstrap de cuenta de la [ADR 0025](../../../docs/adr/0025-ciclo-de-ambiente-en-aws.md). Lo aplica una
vez el operador de la cuenta, con su propia autenticación y un estado propio en el bucket del
bootstrap (`bootstrap/aws-access.tfstate`). Ningún workflow de un ambiente recibe estos permisos.

- **Proveedor OIDC de GitHub** (`token.actions.githubusercontent.com`), uno por cuenta. Si ya existe,
  se pasa su ARN en `github_oidc_provider_arn` y no se crea otro.
- **Permissions boundary de los workloads** (`hexagon-workload-boundary`): el techo de todo rol que
  cree un ambiente (tareas, ejecución y mantenimiento). Solo permite acciones de datos sobre recursos
  con la etiqueta `hexagon:instance` del propio rol, el secreto administrador de su base, sus logs y
  el login de ECR. Nunca IAM, STS ni administración de la cuenta.

Ambos llevan `prevent_destroy`: Apocalypse no los retira. Ver la
[guía del ciclo efímero en AWS](../../../docs/ciclo-efimero-aws.md).
