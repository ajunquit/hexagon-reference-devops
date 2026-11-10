terraform {
  required_version = ">= 1.10.0, < 2.0.0"

  required_providers {
    rabbitmq = {
      source  = "cyrilgdn/rabbitmq"
      version = "~> 1.10"
    }
  }

  backend "http" {}
}
