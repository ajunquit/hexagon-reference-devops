# Terraform

Esta carpeta separa módulos reutilizables de composiciones por ambiente. Las fases 4 a 6
implementan Azure Service Bus, AWS SNS/SQS y RabbitMQ sin ocultar sus diferencias.

- `bootstrap/`: almacenamiento, bloqueo y protección del estado remoto para Azure y AWS.
- `modules/`: una implementación por proveedor y capacidad.
- `environments/`: roots independientes por ambiente y proveedor.

El descriptor `ProductEnvironment` se valida antes de construir un plan. Los módulos reciben datos
ya validados; no descargan ramas mutables ni editan manifiestos de aplicación.

Cada ambiente contiene roots alternativos `azure/`, `aws/` y `rabbitmq/`. Se ejecuta únicamente el
que coincide con el proveedor declarado por el backend. La configuración protegida del backend
remoto se inyecta al ejecutar `terraform init`.

Terraform requerido: `>= 1.10.0, < 2.0.0`. AzureRM se restringe a `~> 5.0`, AWS a `~> 6.0` y el
proveedor RabbitMQ a `~> 1.10`; cada root conserva su lock file. RabbitMQ usa variables efímeras
para las credenciales del proveedor y un backend HTTP remoto con HTTPS y locking externos.
