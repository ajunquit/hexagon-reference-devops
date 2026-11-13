variable "product" { type = string }
variable "environment" {
  type = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Unknown product environment."
  }
}
variable "name_prefix" {
  description = "Account-unique AWS-safe prefix, owned by the product environment."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,18}$", var.name_prefix))
    error_message = "Use a lowercase prefix of 3 to 19 characters."
  }
}
variable "availability_zones" {
  description = "Two zones: the load balancer and the database subnet group require two."
  type        = list(string)
  validation {
    condition     = length(var.availability_zones) == 2 && length(distinct(var.availability_zones)) == 2
    error_message = "Declare exactly two distinct availability zones."
  }
}
variable "vpc_cidr" { type = string }
variable "public_subnet_cidrs" {
  description = "Subnets for the load balancer and the tasks. There is no NAT: tasks reach AWS APIs through their public address."
  type        = list(string)
  validation {
    condition     = length(var.public_subnet_cidrs) == 2 && alltrue([for cidr in var.public_subnet_cidrs : can(cidrhost(cidr, 0))])
    error_message = "Declare two public subnet CIDR blocks."
  }
}
variable "database_subnet_cidrs" {
  description = "Private subnets without any route to the internet."
  type        = list(string)
  validation {
    condition     = length(var.database_subnet_cidrs) == 2 && alltrue([for cidr in var.database_subnet_cidrs : can(cidrhost(cidr, 0))])
    error_message = "Declare two database subnet CIDR blocks."
  }
}
variable "database_name" {
  type = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{0,62}$", var.database_name))
    error_message = "Invalid PostgreSQL database identifier."
  }
}
variable "database_connection_name" {
  type = string
  validation {
    condition     = can(regex("^[A-Za-z][A-Za-z0-9]{0,62}$", var.database_connection_name))
    error_message = "Invalid connection string name."
  }
}
variable "database_instance_class" {
  type     = string
  nullable = false
  default  = "db.t4g.micro"
  validation {
    condition     = can(regex("^db[.][a-z0-9]+[.][a-z0-9]+$", var.database_instance_class))
    error_message = "Invalid RDS instance class."
  }
}
variable "database_storage_gb" {
  type     = number
  nullable = false
  default  = 20
  validation {
    condition     = var.database_storage_gb >= 20 && floor(var.database_storage_gb) == var.database_storage_gb
    error_message = "RDS PostgreSQL requires at least 20 GB."
  }
}
variable "database_multi_az" {
  description = "A standby in a second zone. Off by default: it doubles the cost of the database."
  type        = bool
  nullable    = false
  default     = false
}
variable "messaging_enabled" {
  type    = bool
  default = true
  validation {
    condition     = var.messaging_enabled || alltrue([for workload in values(var.workloads) : workload.kind == "api"])
    error_message = "Messaging-free hosting supports only API workloads."
  }
}
variable "auth" {
  description = "External Hexagon Auth bindings, or a null authority for integrated Keycloak."
  type        = object({ authority = string, client_id = string, audience = string, api_scope = string })
  validation {
    condition     = var.auth.authority == null ? true : (can(regex("^https://[A-Za-z0-9.-]+(?::443)?/[^?#@]+$", var.auth.authority)) && !endswith(var.auth.authority, "/"))
    error_message = "Hexagon Auth requires a public HTTPS issuer."
  }
}
variable "workloads" {
  description = "Fargate sizes: cpu in CPU units and memory in MiB, as ECS accepts them."
  type = map(object({
    name        = string, kind = string, image = string,
    http_ports  = list(number), health_port = number,
    environment = map(string), secret_references = map(object({ secret_arn = string })),
    cpu         = number, memory = number, min_replicas = number, max_replicas = number
  }))
  validation {
    condition = alltrue([for workload in values(var.workloads) :
      contains(["api", "consumer"], workload.kind) &&
      can(regex("^[a-z][a-z0-9-]{0,62}$", workload.name)) &&
      can(regex("^[0-9]{12}[.]dkr[.]ecr[.][a-z0-9-]+[.]amazonaws[.]com/[a-z0-9._/-]+@sha256:[0-9a-f]{64}$", workload.image)) &&
      startswith(workload.image, "${local.registry}/") &&
      workload.health_port == 8081 && workload.http_ports == (workload.kind == "api" ? tolist([8080, 8081]) : tolist([8081])) &&
      contains(lookup(local.fargate_memory, tostring(workload.cpu), []), workload.memory) &&
      workload.min_replicas >= 1 && workload.max_replicas >= workload.min_replicas
    ]) && length([for workload in values(var.workloads) : workload if workload.kind == "api"]) == 1
    error_message = "Exactly one API, immutable ECR image digests of this account, health ports, a valid Fargate size and at least one replica are required."
  }
  validation {
    condition = alltrue([for workload in values(var.workloads) :
      alltrue([for key in keys(workload.environment) : !can(regex("(?i)(password|token|secret)", key))]) &&
      length(setintersection(toset(keys(workload.environment)), toset(keys(workload.secret_references)))) == 0 &&
      alltrue([for secret in values(workload.secret_references) :
        can(regex("^arn:aws:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:[A-Za-z0-9/_+=.@-]+$", secret.secret_arn))
      ])
    ])
    error_message = "Use Secrets Manager references for credentials, without duplicate environment keys."
  }
}
variable "migration_workload" {
  type = string
  validation {
    condition     = try(var.workloads[var.migration_workload].kind == "api", false)
    error_message = "Migrations must use the API artifact."
  }
}
variable "bootstrap_image" {
  type = string
  validation {
    condition     = can(regex("^[0-9]{12}[.]dkr[.]ecr[.][a-z0-9-]+[.]amazonaws[.]com/[a-z0-9._/-]+@sha256:[0-9a-f]{64}$", var.bootstrap_image)) && startswith(var.bootstrap_image, "${local.registry}/")
    error_message = "The database bootstrap task requires an immutable ECR image digest of this account."
  }
}
variable "application_rollout_enabled" {
  description = "Enable only after the database access, migration and identity tasks succeed."
  type        = bool
  default     = false
  validation {
    condition     = !var.application_rollout_enabled || (var.maintenance_jobs_enabled && (var.keycloak == null || var.keycloak_rollout_enabled))
    error_message = "Create and complete the maintenance tasks before enabling application rollout."
  }
}
variable "maintenance_jobs_enabled" {
  description = "Enable after the initial infrastructure exists and immutable images are available in ECR."
  type        = bool
  default     = false
}
variable "log_retention_days" {
  type     = number
  nullable = false
  default  = 7
  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90], var.log_retention_days)
    error_message = "Use a supported CloudWatch retention of at most 90 days."
  }
}
variable "tags" { type = map(string) }
variable "workload_boundary_arn" {
  description = "Permissions boundary of aws-access, required on every role inside a reservation (ADR 0025)."
  type        = string
  default     = null
  validation {
    condition     = var.workload_boundary_arn == null || can(regex("^arn:aws:iam::[0-9]{12}:policy/[A-Za-z0-9+=,.@_-]+$", var.workload_boundary_arn))
    error_message = "Use the workload boundary ARN of aws-access."
  }
}

variable "acceptance_fixture" {
  description = "Optional isolated initial tenants for ephemeral acceptance; never an identity credential."
  type        = object({ instanceId = string, subjectId = string, tenant = string, otherTenant = string })
  default     = null
  validation {
    condition = var.acceptance_fixture == null ? true : (
      var.environment != "prod" && can(regex("^run-[1-9][0-9]{0,19}-[1-9][0-9]{0,3}$", var.acceptance_fixture.instanceId)) &&
      can(regex("^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$", var.acceptance_fixture.subjectId)) &&
      var.acceptance_fixture.tenant == "e2e-${var.acceptance_fixture.instanceId}-a" &&
      var.acceptance_fixture.otherTenant == "e2e-${var.acceptance_fixture.instanceId}-b"
    )
    error_message = "Acceptance fixtures require dev/staging, an ephemeral instance, a subject UUID and exactly its two isolated tenants."
  }
}
