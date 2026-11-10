# Ambiente prod

Roots de Terraform para producción:

- `azure/`: backend `azurerm` y módulo Azure Service Bus;
- `aws/`: backend S3 y módulo AWS SNS/SQS;
- `rabbitmq/`: backend HTTP remoto y módulo de topología RabbitMQ.

Se usa solo el root que coincide con el proveedor del manifiesto backend. Su backend se configura
externamente con una key o URL exclusiva de `prod`. No se confirma `*.auto.tfvars.json` ni se
ejecuta `apply` local contra este ambiente.
