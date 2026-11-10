# ADR 0007: topología de RabbitMQ con DLX por cola

- Estado: Aceptada
- Fecha: 2026-11-08

## Contexto

El backend puede elegir RabbitMQ sin cambiar dominio, aplicación, outbox o inbox. Su manifiesto
declara destinos, Consumers, workloads y routing lógicos, pero no debe decidir nombres físicos,
límites de entrega, usuarios, DLX o DLQ. Esas decisiones pertenecen al repositorio DevOps y varían
por ambiente y cola.

RabbitMQ no incorpora una DLQ obligatoria por cola. Las colas quorum admiten `delivery-limit`, y
una policy puede enviar los mensajes que superen ese límite a un dead-letter exchange. Configurar
el DLX mediante policies permite cambiar la operación sin redeclarar la cola.

El proveedor Terraform disponible administra usuarios con una contraseña que persiste en texto
plano dentro del estado. Ese comportamiento contradice la regla de no almacenar secretos en estado
o planes.

## Decisión

1. `RabbitMqPolicy` v1 combina el manifiesto backend inmutable con nombres físicos, virtual host,
   límite de entrega, DLX/DLQ opcional y un usuario preexistente distinto por workload.
2. Terraform crea un virtual host dedicado, exchanges `topic`, una cola quorum durable por Consumer
   y bindings `#` o por tipo de evento.
3. Toda cola fuente declara un `delivery-limit`. Si `deadLetter.enabled` es `true`, Terraform crea
   un exchange `direct` y una DLQ quorum dedicados, y configura dead-lettering `at-least-once`. Si
   es `false`, no crea DLX/DLQ y superar el límite descarta el mensaje.
4. Las aplicaciones reciben `configure = ^$`. Un publicador solo escribe en sus exchanges y tipos
   de evento; un Consumer solo lee sus colas fuente. Ningún workload accede a las DLQ.
5. El módulo no crea usuarios RabbitMQ. Sus nombres y permisos sí están en IaC, pero sus cuentas y
   connection strings se entregan desde el gestor de secretos del ambiente. Las credenciales del
   proveedor son variables Terraform `sensitive` y `ephemeral`.
6. Los roots de RabbitMQ usan un backend HTTP remoto y parcial, con HTTPS y locking configurados
   externamente. Así la topología no depende de que el broker esté alojado en Azure o AWS.
7. El módulo administra la topología de un clúster existente; crear el clúster, su red, TLS y alta
   disponibilidad pertenece a la futura composición de hosting.

## Consecuencias

- Cada cola conserva la libertad de habilitar o no DLX/DLQ sin trasladar esa decisión al runtime.
- El inbox puede absorber duplicados producidos por la entrega `at-least-once`.
- Un mensaje que supera el límite se descarta deliberadamente cuando la cola deshabilita DLQ.
- El `apply` falla si los usuarios declarados todavía no existen; no se degrada a permisos
  compartidos ni se versionan contraseñas.
- Métricas, alertas, inspección, retención y reproducción de DLQ permanecen en la fase 8.
- La validación automatizada y el despliegue con credenciales federadas permanecen en la fase 9.

## Referencias

- [Dead Letter Exchanges](https://www.rabbitmq.com/docs/dlx)
- [Quorum Queues](https://www.rabbitmq.com/docs/quorum-queues)
- [Access Control](https://www.rabbitmq.com/docs/access-control)
- [Terraform: datos sensibles y valores efímeros](https://developer.hashicorp.com/terraform/language/manage-sensitive-data)
