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

## Entradas y raíces

`terraform/environments/{dev,staging,prod}/hosting-aws` componen el módulo con un backend S3 y una
key exclusiva, como `hexagon-example/dev/hosting-aws.tfstate`. Cada raíz acepta solo su ambiente y
fija el proveedor en la cuenta declarada (`allowed_account_ids`).

`AwsHostingPolicy` v1 declara la cuenta, la región, la red, las tallas y los bindings de cada
workload. Véase `examples/aws-hosting-policy.json`, sin secretos. Fargate se expresa en unidades de
CPU y MiB (desde `256` / `512`); las tallas de base de datos y logs son opcionales y, si se omiten,
toman los mínimos del módulo. Las credenciales van en `secret_references` como ARN de Secrets
Manager. Keycloak integrado declara solo imagen, realm y usuario inicial: sus secretos los crea el
módulo vacíos.

```powershell
pwsh ./scripts/Export-AwsHostingInputs.ps1 -Descriptor <descriptor.json> `
  -Release <release.json> -Policy <aws-hosting-policy.json> `
  -Output ./terraform/environments/dev/hosting-aws/generated.auto.tfvars.json
```

La exportación aplica las mismas comprobaciones que la de Azure (fuentes fijadas, workloads,
puertos, migración, identidad y mensajería). Cada imagen pasa a
`<cuenta>.dkr.ecr.<región>.amazonaws.com/<name_prefix>/<artefacto>@sha256:<digest>`, con el mismo
digest del release. La activación empieza en `false`, y el archivo generado no se confirma.

## Orden de activación

1. **Infraestructura:** sin tareas. La entrega copia las imágenes a ECR por digest.
2. **`maintenance_jobs_enabled`:** crea las definiciones de las tareas de mantenimiento. La entrega
   las ejecuta una vez, en este orden, con `ecs:RunTask` y la red de la salida `task_network`
   ([ADR 0024](adr/0024-credenciales-de-base-de-datos-en-aws.md)):
   1. `database-credentials`, con el usuario maestro de RDS: crea un usuario de mantenimiento, que
      pasa a ser dueño de la base, y un usuario por workload. Escribe sus cadenas de conexión en
      los secretos vacíos.
   2. `migrations`, con el usuario de mantenimiento.
   3. `database-access`, con el usuario de mantenimiento: concede los roles de runtime.
   4. Con Keycloak, `keycloak-database`: su rol, su esquema y la contraseña de su administrador
      inicial.

   Las credenciales las genera la tarea; ningún operador las introduce. Si un secreto ya tiene
   valor, se **conserva**: repetir las tareas no rota nada.
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

- Entrega (copia OCI por digest, tareas de mantenimiento, rollout, publicación de la SPA e
  invalidación de CloudFront) y Genesis/Apocalypse en AWS.
- Rotación explícita de credenciales, cuando el dueño la ordene.
- Comprobar en la validación real que el backend usa la contraseña de la cadena de conexión y no
  la credencial de Azure, que el maestro de RDS puede crear el usuario de mantenimiento con
  `BYPASSRLS` y transferirle la base, y que Keycloak funciona bajo `/auth` detrás de CloudFront.

Este módulo no despliega nada por sí mismo: las pruebas usan proveedores simulados.
