# Terraform

Esta carpeta separa módulos reutilizables de composiciones por ambiente. Cada proveedor de mensajería
y cada nube tienen su implementación, sin ocultar sus diferencias.

- `bootstrap/`: almacenamiento, bloqueo y protección del estado remoto de cada nube.
- `modules/`: una implementación por proveedor y capacidad.
- `environments/`: roots independientes por ambiente y proveedor.

El descriptor `ProductEnvironment` se valida antes de construir un plan. Los módulos reciben datos
ya validados; no descargan ramas mutables ni editan manifiestos de aplicación.

Cada ambiente contiene roots alternativos de mensajería: uno por nube y `rabbitmq/`. Se ejecuta
únicamente el que coincide con el proveedor declarado por el backend. La configuración protegida
del backend remoto se inyecta al ejecutar `terraform init`.

Terraform requerido: `>= 1.10.0, < 2.0.0`. Cada root fija la versión mayor de su proveedor y
conserva su lock file; el proveedor RabbitMQ se restringe a `~> 1.10`. RabbitMQ usa variables
efímeras para las credenciales del proveedor y un backend HTTP remoto con HTTPS y locking externos.
