provider "aws" {
  region = var.region
  default_tags {
    # Scope of the instance (ADR 0025): the reservation authorizes changes through these tags.
    tags = merge(
      { "hexagon:product" = var.product, "hexagon:environment" = var.environment, "hexagon:instance" = var.instance_id },
      var.name_prefix == null ? {} : { "hexagon:name-prefix" = var.name_prefix }
    )
  }
}
