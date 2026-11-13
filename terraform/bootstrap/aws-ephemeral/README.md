# Reserva efímera AWS

Reserva de una instancia `run-ID-attempt` en `dev` o `staging`, según la
[ADR 0025](../../../docs/adr/0025-ciclo-de-ambiente-en-aws.md). Es el equivalente de
`azure-ephemeral`. La aplica el operador del bootstrap, con estado propio en
`bootstrap/ephemeral/<producto>/<ambiente>/<instancia>.tfstate`.

Crea un **rol de despliegue** que solo puede asumir GitHub Actions desde el repositorio DevOps del
producto y el Environment `<ambiente>-<instancia>`. Sus permisos, en cinco políticas administradas:

| Política | Qué permite |
| --- | --- |
| `state` | Estado, inventario, journal, lease y snapshots solo bajo `<producto>/<ambiente>/<instancia>/` del bucket; lectura y observación (Cloud Control, Tagging API) |
| `create` | Crear recursos solo con las etiquetas `hexagon:*` de la instancia |
| `manage` | Modificar y borrar solo recursos con la etiqueta `hexagon:instance` de la instancia |
| `named` | Recursos cuyas acciones no llevan etiquetas, por el **prefijo corto**: bucket web, funciones de CloudFront, logs, colas, topics, secretos, ECR, alias KMS y RDS. Roles IAM solo con el prefijo y el boundary de `aws-access`; `iam:PassRole` solo hacia ECS |
| `guardrails` | Denegaciones explícitas: usuarios y claves IAM, federación, cuenta, retirar el boundary, escribir o borrar etiquetas `hexagon:*` ajenas y objetos fuera de sus prefijos |

El prefijo corto (`name_prefix`) es `<base>-<6 hex>`, la misma regla que valida el motor. El rol de
despliegue no lleva ese prefijo, así que la instancia no puede modificarlo.

**Límites conocidos:**

- **Confianza de los roles:** IAM no permite condicionar la política de confianza de los roles que
  crea una instancia. El boundary limita igualmente lo que esos roles alcanzan a los datos de la
  propia instancia.
- **Lectura:** las acciones `Describe`/`List` son de cuenta.

Lo que una instancia puede tocar y lo que se le deniega lo acredita el diagnóstico de aislamiento
con la identidad federada real, no estas pruebas con proveedores simulados.
