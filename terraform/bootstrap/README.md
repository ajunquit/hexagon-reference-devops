# Bootstrap del estado remoto

Azure y AWS crean su almacenamiento remoto antes de crear la topología. RabbitMQ usa un servicio
HTTP remoto existente porque su clúster puede estar alojado en cualquier plataforma.

## Azure

`azure/` crea:

- grupo de recursos dedicado;
- cuenta Storage con autenticación por Microsoft Entra ID, TLS 1.2 y cifrado de infraestructura;
- contenedor privado, versionado y recuperación durante 30 días;
- lock `CanNotDelete` sobre la cuenta;
- keys separadas para bootstrap, `dev`, `staging` y `prod`.

## AWS

`aws/` crea:

- bucket S3 privado con Public Access Block y acceso solo mediante TLS;
- cifrado KMS con rotación y ventana de eliminación de 30 días;
- versionado para recuperar estados borrados o sobrescritos;
- protección `prevent_destroy` del bucket;
- keys separadas para bootstrap, `dev`, `staging` y `prod`.

El backend S3 usa el lockfile nativo de Terraform (`use_lockfile = true`); no crea una tabla
DynamoDB para el mecanismo de locking deprecado.

## RabbitMQ

El root `rabbitmq/` no crea un almacén de estado específico de cloud. Usa el backend HTTP de
Terraform con una URL HTTPS distinta por producto y ambiente. `TF_HTTP_LOCK_ADDRESS` y
`TF_HTTP_UNLOCK_ADDRESS` son obligatorios en la operación para conservar locking; las credenciales
se inyectan mediante las variables de entorno del backend y nunca se escriben en archivos.

El bootstrap no puede depender inicialmente del backend que crea. El comando Azure genera una copia
controlada con backend local, aplica un plan revisado y transfiere el estado a un backend remoto
separado con `state push` sin force y con locking. Contrasta lineage/serial/recursos y solo entonces
reconfigura el directorio original y elimina las copias locales conocidas. Azure usa
`use_azuread_auth=true`; AWS usa KMS y `use_lockfile=true`. Los estados nunca se confirman en Git.

Las credenciales y la identidad del operador se suministran fuera del repositorio. La
[guía de bootstrap](../../docs/bootstrap-plataformas.md) documenta la ejecución Azure por etapas,
contenedores y grupos persistentes, identidades federadas en `azure-access/`, verificación y
recuperación. AWS conserva validación/mocks; su coordinador de ejecución sigue pendiente.
