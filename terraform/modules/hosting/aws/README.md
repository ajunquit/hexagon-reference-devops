# Hosting AWS de referencia

Módulo de la [ADR 0023](../../../../docs/adr/0023-referencia-de-hosting-en-aws.md): ECS Fargate para
API/Workers, RDS PostgreSQL 17 privado, ECR inmutable, S3 y CloudFront, un ALB interno detrás de un
VPC origin, roles IAM separados y tareas de mantenimiento. Admite opcionalmente Keycloak integrado
en `dev`, bajo `/auth` del mismo origen. No implementa el módulo Auth ni la topología de mensajería:
expone los roles de tarea para que sus políticas se adjunten.

- **Sin NAT:** las tareas usan subredes públicas con IP pública y un security group que solo acepta
  el balanceador; la base de datos usa subredes privadas sin ruta a internet.
- **Credenciales:** RDS administra la contraseña maestra en Secrets Manager. Los secretos de las
  cadenas de conexión se crean vacíos; la tarea `database-access` los rellena. Terraform nunca
  conoce un valor.
- **Activación por etapas:** el estado inicial no crea tareas; `maintenance_jobs_enabled` crea las
  definiciones de mantenimiento, que la entrega ejecuta con `ecs:RunTask`, y
  `application_rollout_enabled` crea los servicios.
- **Tallas mínimas por defecto:** `db.t4g.micro`, 20 GB, una zona, backup de un día fuera de prod y
  logs de siete días. Las tallas de Fargate las fija cada root.

Las imágenes deben vivir en ECR de la misma cuenta y región, en repositorios
`<name_prefix>/<artefacto>`, fijadas por digest. `terraform test` usa proveedores simulados y no
aprovisiona recursos. Consulta la [guía de hosting AWS](../../../../docs/hosting-aws.md).
