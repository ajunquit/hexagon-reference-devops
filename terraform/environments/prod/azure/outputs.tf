output "azure_service_bus" {
  description = "Azure Service Bus physical mappings and runtime bindings."
  value = {
    namespace         = module.azure_service_bus.namespace
    destinations      = module.azure_service_bus.destinations
    consumers         = module.azure_service_bus.consumers
    workload_bindings = module.azure_service_bus.workload_bindings
  }
}
