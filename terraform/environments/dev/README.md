# Ambiente dev

Roots de Terraform para desarrollo compartido:

- `azure/`: backend `azurerm` y módulo Azure Service Bus;
- `aws/`: backend S3 y módulo AWS SNS/SQS;
- `rabbitmq/`: backend HTTP remoto y módulo de topología RabbitMQ;
- `hosting-azure/`: backend `azurerm` y [hosting Azure](../../../docs/hosting-azure.md);
- `hosting-aws/`: backend S3 y [hosting AWS](../../../docs/hosting-aws.md).

Se usa solo el root de mensajería que coincide con el proveedor del manifiesto backend y el de
hosting de la nube del ambiente. Su backend se configura
externamente con una key o URL exclusiva de `dev`. No se confirma `*.auto.tfvars.json` ni se
ejecuta `apply` local contra este ambiente.
