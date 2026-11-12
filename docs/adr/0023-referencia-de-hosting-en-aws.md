# ADR 0023: referencia de hosting en AWS administrado

- Estado: aceptada
- Fecha: 2026-11-12

## Contexto

La [ADR 0010](0010-primera-referencia-de-hosting-en-azure.md) definió Azure como primera referencia
y previó composiciones de AWS que consumen los mismos artefactos y contratos con adaptadores e
identidades propios. Un producto desplegará en AWS, con el objetivo inicial de validar que la
infraestructura sostiene la aplicación y se retira por completo. El dueño priorizó el **coste
mínimo**: tallas pequeñas, capas gratuitas y ningún recurso fijo evitable.

## Decisión

- **Cómputo:** API, Workers, Keycloak y las tareas de mantenimiento corren en **ECS Fargate**, con
  imágenes OCI fijadas por digest en **ECR**, repositorios inmutables por ambiente y un rol IAM de
  tarea por workload. El rol de ejecución de cada workload solo lee sus propios secretos.
- **Red sin NAT en los tres ambientes:** las tareas usan subredes públicas con dirección pública y
  un security group que solo acepta tráfico del balanceador. PostgreSQL vive en subredes privadas
  sin ruta a internet. Un NAT Gateway puede volver con otra decisión del dueño.
- **Publicación sin dominio propio:** un único **CloudFront** con su HTTPS por defecto sirve la SPA
  desde un bucket **S3** privado (Origin Access Control) y enruta `/api/*` y, en dev, `/auth/*` a un
  **ALB interno** mediante un *VPC origin*. El balanceador no tiene dirección pública y el tráfico
  entre CloudFront y las aplicaciones no sale de la red de AWS. Al compartir origen, la API y la
  SPA no dependen de CORS entre dominios. El fallback de la SPA es una CloudFront Function en la
  ruta por defecto, para que un 404 de la API siga siendo ProblemDetails.
- **Datos:** **RDS PostgreSQL 17** privado, cifrado y con la contraseña administradora gestionada
  por RDS en Secrets Manager. Cada workload se conecta con su propio usuario de base de datos y
  **contraseña en Secrets Manager**: Terraform crea los secretos vacíos y la tarea `database-access`
  crea los usuarios y escribe sus cadenas de conexión. Ninguna credencial pasa por planes, estado
  ni descriptores. La autenticación IAM de RDS (sin contraseñas, equivalente a Entra) queda como
  endurecimiento posterior, porque exige cambiar el core y la plantilla backend.
- **Orden:** como en Azure, primero la infraestructura, luego las tareas de mantenimiento
  (`database-access`, migraciones y, en dev, la base de Keycloak) y por último los workloads.
- **Keycloak integrado** solo en dev, bajo `/auth` del mismo origen, como en la
  [ADR 0021](0021-keycloak-integrado-en-la-base-del-producto-dev.md).
- **Tallas mínimas por defecto:** `db.t4g.micro` con 20 GB y una zona, backup de un día fuera de
  prod, Fargate desde 0,25 vCPU / 512 MiB y logs con siete días de retención.

## Consecuencias

- El módulo `terraform/modules/hosting/aws` es independiente del de Azure (regla 6): no hay una
  abstracción común.
- Sin NAT, cada tarea tiene una IPv4 pública con coste propio y defensa en profundidad menor que en
  subredes privadas. Se acepta para validar; los datos permanecen en subredes privadas.
- Entre CloudFront y el ALB el tráfico es HTTP dentro de la red de AWS. Un dominio propio con
  certificado ACM permitiría HTTPS de extremo a extremo.
- Keycloak usa `sslmode=require` contra RDS: el certificado de RDS no está en el almacén de
  confianza de la imagen oficial. Verificarlo exige añadir la CA de RDS.
- Que el backend use la contraseña de la cadena de conexión en lugar de la credencial de Azure se
  comprueba en la validación real.
- Este incremento define y prueba el módulo con proveedores simulados. Las raíces por ambiente, la
  variante AWS de la tarea `database-access`, la exportación desde contratos, la entrega y
  Genesis/Apocalypse en AWS llegan en incrementos siguientes. Desplegar requiere una orden expresa.
