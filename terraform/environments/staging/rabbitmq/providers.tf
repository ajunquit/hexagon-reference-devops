provider "rabbitmq" {
  endpoint = var.rabbitmq_management_endpoint
  username = var.rabbitmq_management_username
  password = var.rabbitmq_management_password
}
