# Bootstrap del estado remoto

Cada nube crea su almacenamiento remoto antes de crear la topología y lo documenta en su carpeta
(`terraform/bootstrap/<nube>/README.md`), junto a sus identidades federadas (`<nube>-access/`) y su
reserva efímera (`<nube>-ephemeral/`). RabbitMQ usa un servicio HTTP remoto existente porque su
clúster puede estar alojado en cualquier plataforma.

## RabbitMQ

El root `rabbitmq/` no crea un almacén de estado específico de cloud. Usa el backend HTTP de
Terraform con una URL HTTPS distinta por producto y ambiente. `TF_HTTP_LOCK_ADDRESS` y
`TF_HTTP_UNLOCK_ADDRESS` son obligatorios en la operación para conservar locking; las credenciales
se inyectan mediante las variables de entorno del backend y nunca se escriben en archivos.

Ningún bootstrap depende inicialmente del backend que crea: aplica un plan revisado con backend
local y transfiere el estado al backend remoto con locking. Los estados nunca se confirman en Git.
Las credenciales y la identidad del operador se suministran fuera del repositorio.
