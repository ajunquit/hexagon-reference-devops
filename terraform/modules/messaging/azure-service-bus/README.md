# Azure Service Bus

La fase 8 acepta `operations` para definir alertas Azure Monitor y permisos de operadores distintos
de los workloads. `EntityName` observa el topic: se agrupan umbrales de consumidores por su mínimo,
sin atribuir métricas a una suscripción. Consulta [operación](../../../../docs/operacion-mensajeria.md).

Módulo de la fase 4. Materializa la topología lógica del backend con semántica nativa de Azure:

- un namespace `Standard` o `Premium`, con TLS 1.2 y autenticación local deshabilitada;
- un topic por destino lógico;
- una suscripción por Consumer;
- una regla explícita `1=1` para routing `all`, o una regla de correlación por tipo de evento para
  routing `include`;
- `MaxDeliveryCount`, lock, TTL y dead-letter por expiración por suscripción;
- rol `Azure Service Bus Data Sender` en el topic para cada publicador;
- rol `Azure Service Bus Data Receiver` en la suscripción para cada Consumer;
- bindings no secretos por workload.

El adaptador backend publica el tipo de evento en `Subject`. En Azure, la regla de correlación usa
`label`, que corresponde a ese campo. El root debe configurar
`features.servicebus.auto_delete_subscription_default_rule = true`: así desaparece `$Default` y
solo quedan las reglas declaradas por Terraform.

Azure Service Bus siempre crea una DLQ para cada suscripción. No existe una opción para desactivarla
y agotar `MaxDeliveryCount` siempre envía el mensaje allí. La política solo decide si la expiración
también lo hace. La retención operativa, alertas y reproducción se añaden en la fase 8.

## Pruebas

Requiere Terraform 1.7 o posterior:

```powershell
terraform -chdir=terraform/modules/messaging/azure-service-bus init -backend=false
terraform -chdir=terraform/modules/messaging/azure-service-bus test
```

La prueba usa el proveedor simulado de Terraform: no necesita una suscripción de Azure ni crea
recursos.
