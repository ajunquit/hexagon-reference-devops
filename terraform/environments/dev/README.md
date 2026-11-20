# Ambiente dev

Roots de Terraform para desarrollo compartido:

- `rabbitmq/`: backend HTTP remoto y módulo de topología RabbitMQ;
- un root de mensajería y uno de hosting (`hosting-<nube>/`) por cada nube de la plantilla, descritos
  en su guía de hosting.

Se usa solo el root de mensajería que coincide con el proveedor del manifiesto backend y el de
hosting de la nube del ambiente. Su backend se configura
externamente con una key o URL exclusiva de `dev`. No se confirma `*.auto.tfvars.json` ni se
ejecuta `apply` local contra este ambiente.
