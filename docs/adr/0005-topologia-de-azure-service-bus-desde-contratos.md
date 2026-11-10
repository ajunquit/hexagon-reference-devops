# 0005. Topología de Azure Service Bus desde contratos separados

- **Estado:** Aceptada
- **Fecha:** 2026-11-08

## Contexto

El backend declara requisitos lógicos versionados, pero no debe decidir nombres, SKU, reintentos,
DLQ, identidades ni red. Esas decisiones cambian por ambiente y pertenecen al repositorio DevOps.
Copiar toda la topología en ambos contratos permitiría divergencias; hacer que Terraform leyera una
rama mutable rompería la promoción inmutable.

Azure Service Bus añade semántica propia: cada suscripción tiene una DLQ incorporada, los mensajes
que exceden `MaxDeliveryCount` siempre llegan allí, y una suscripción nueva incluye una regla
`$Default` que recibiría todos los mensajes si no se elimina.

## Decisión

- Mantener el manifiesto backend como fuente de destinos, Consumers, workloads, eventos y routing.
- Crear `AzureServiceBusPolicy` v1 por producto y ambiente para la política física y operativa.
- Materializar variables Terraform solo después de validar esquema, producto, ambiente, commit,
  SHA-256 y correspondencia exacta entre ambas fuentes.
- Crear un topic por destino y una suscripción por Consumer.
- Eliminar `$Default` y crear una regla explícita: `1=1` para `all`, o correlación por `Subject` para
  cada evento de `include`.
- Fijar autenticación local en deshabilitada y conceder RBAC en el menor alcance posible: `Data
  Sender` en cada topic y `Data Receiver` en cada suscripción.
- No modelar `dlq.enabled`: en Azure la DLQ existe siempre. Sí se configura por suscripción si la
  expiración envía allí el mensaje.
- Mantener métricas, alertas, cuarentena y reproducción fuera de esta fase; pertenecen a la fase 8.

## Consecuencias

- Cambiar TTL, SKU, nombre físico o entregas no obliga a recompilar el backend.
- Cambiar destino, Consumer, workload o routing exige primero otro commit del contrato backend.
- Un filtro incompleto o una identidad ausente falla antes del plan.
- Los procesos no reciben permisos administrativos ni crean topología en runtime.
- AWS y RabbitMQ conservarán contratos y módulos distintos para expresar su DLQ/DLX opcional sin
  fingir que tienen la semántica de Azure.
