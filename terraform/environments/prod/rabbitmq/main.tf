module "messaging" {
  operations = var.operations
  source     = "../../../modules/messaging/rabbitmq"

  virtual_host = var.virtual_host
  destinations = var.destinations
  consumers    = var.consumers
}
