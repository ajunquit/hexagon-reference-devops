# Referencia de hosting: AWS administrado

Composición de la [ADR 0023](adr/0023-referencia-de-hosting-en-aws.md), equivalente a la
[referencia Azure](hosting-azure.md): **ECS Fargate, RDS PostgreSQL, S3 y CloudFront**, con
Terraform. Consume los mismos contratos lógicos y las mismas imágenes OCI. El broker se elige por
separado; la mensajería AWS SNS/SQS vive en su propio módulo.

## Recursos

`terraform/modules/hosting/aws` crea, por producto y ambiente:

- una VPC con dos subredes públicas (balanceador y tareas) y dos privadas (base de datos), un
  internet gateway y **ningún NAT**;
- security groups encadenados: CloudFront → balanceador → tareas → base de datos;
- RDS PostgreSQL 17 privado, cifrado, con la contraseña maestra administrada por RDS en Secrets
  Manager y sin autenticación IAM;
- repositorios ECR inmutables `<name_prefix>/<artefacto>` con escaneo al subir;
- un clúster ECS, un grupo de logs, un rol de tarea por workload (sin permisos, para la mensajería),
  un rol de mantenimiento y roles de ejecución que leen solo los secretos de su contenedor;
- secretos vacíos para la cadena de conexión de cada workload y de las migraciones;
- un ALB **interno** con la regla `/api/*`, alcanzado por CloudFront mediante un VPC origin;
- un bucket S3 privado para la SPA y una distribución CloudFront con HTTPS por defecto, la SPA en la
  ruta por defecto (con fallback por CloudFront Function) y `/api/*` hacia el ALB.

## Orden de activación

1. **Infraestructura:** sin tareas. La entrega copia las imágenes a ECR por digest.
2. **`maintenance_jobs_enabled`:** crea las definiciones `database-access`, `migrations` y, con
   Keycloak, `keycloak-database`. La entrega las ejecuta una vez, en ese orden, con `ecs:RunTask`
   y la red de la salida `task_network`. `database-access` usa el secreto administrador de RDS,
   crea un usuario por workload y otro de mantenimiento, y escribe sus cadenas de conexión en los
   secretos vacíos.
3. **`keycloak_rollout_enabled`** (solo dev con Keycloak integrado) y
   **`application_rollout_enabled`:** crean los servicios, con autoescalado por CPU cuando
   `max_replicas` supera a `min_replicas`.

## Publicación y autenticación

Todo cuelga de un solo origen HTTPS, `https://<distribución>.cloudfront.net`:

| Ruta | Destino |
| --- | --- |
| `/` y rutas de la SPA | S3, con fallback a `index.html` solo para rutas sin extensión |
| `/api/*` | API en Fargate, sin caché |
| `/auth/*` (solo dev con Keycloak integrado) | Keycloak con `KC_HTTP_RELATIVE_PATH=/auth` |

La API recibe `AllowedOrigins` con ese mismo origen. Con Keycloak integrado, el emisor es
`https://<distribución>.cloudfront.net/auth/realms/<realm>`, y la salida `frontend_authentication`
lo entrega a la configuración pública de la SPA.

## Coste

Las tallas por defecto son las mínimas: `db.t4g.micro` con 20 GB, una zona y backup de un día fuera
de prod; logs de siete días. Las tallas de Fargate las fija cada root, desde 0,25 vCPU / 512 MiB.
Sin NAT, cada tarea paga su IPv4 pública. CloudFront, S3, ECR y, en cuentas elegibles, el ALB y RDS
tienen capa gratuita.

## Pendiente

- Raíces `environments/{dev,staging,prod}/hosting-aws` y exportación de entradas desde los
  contratos de las aplicaciones.
- Variante AWS de `Hexagon.Database.Bootstrap`: usuarios con contraseña y escritura en Secrets
  Manager.
- Entrega (copia OCI por digest, tareas de mantenimiento, rollout, publicación de la SPA e
  invalidación de CloudFront) y Genesis/Apocalypse en AWS.
- Comprobar en la validación real que el backend usa la contraseña de la cadena de conexión y no
  la credencial de Azure, y que Keycloak funciona bajo `/auth` detrás de CloudFront.

Este módulo no despliega nada por sí mismo: las pruebas usan proveedores simulados.
