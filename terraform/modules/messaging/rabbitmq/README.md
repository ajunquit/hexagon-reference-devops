# RabbitMQ

La fase 8 acepta `operations` para asignar permisos a usuarios operativos existentes, separados de
los workloads. Genera reglas Prometheus por separado y protege cada DLQ con una política de
`delivery-limit = -1` sin cambiar su declaración. Consulta [operación](../../../../docs/operacion-mensajeria.md).

Módulo de la fase 6. Crea un virtual host dedicado, exchanges, colas quorum, bindings, límites de
entrega y DLX/DLQ opcionales por Consumer. No crea el clúster RabbitMQ ni usuarios con contraseña.

Los usuarios declarados deben existir antes del `apply`. Terraform les asigna permisos mínimos:

- `configure = ^$`: la aplicación no crea ni modifica topología;
- `write`: solo los exchanges donde publica el workload;
- `read`: solo sus colas de consumo;
- permisos de topic: solo los tipos de evento declarados por el backend.

El proveedor `cyrilgdn/rabbitmq` almacena la contraseña de `rabbitmq_user` en texto plano dentro del
estado, por eso este módulo no usa ese recurso. El root recibe las credenciales administrativas como
variables `sensitive` y `ephemeral`; el gestor de secretos del despliegue entrega después las
connection strings de los workloads.

Cada cola fuente tiene un `delivery-limit`. Si `dead_letter.enabled = true`, el módulo crea un DLX
directo y una DLQ quorum dedicados, y usa dead-lettering `at-least-once`. Si es `false`, superar el
límite descarta el mensaje y no crea recursos de dead-letter.
