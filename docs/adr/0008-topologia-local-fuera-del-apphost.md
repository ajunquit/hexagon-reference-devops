# ADR 0008: la topología local pertenece a DevOps

- Estado: aceptada
- Fecha: 2026-11-09

## Contexto

La API y los Workers ya declaran requisitos lógicos mediante `BackendMessagingRequirements`, y los
ambientes desplegados materializan la topología con políticas propiedad de DevOps. Sin embargo, el
AppHost todavía creaba el broker y la topología temporal para desarrollo local. Eso mantenía dos
fuentes de verdad y obligaba al backend a conocer detalles físicos de Azure, AWS o RabbitMQ.

El AppHost sí debe orquestar los procesos del producto y entregarles configuración. No debe decidir
topics, suscripciones, colas, routing, reintentos, DLQ o DLX.

## Decisión

La instancia DevOps del producto es también propietaria de la topología local:

1. `Start-LocalMessaging.ps1` lee y valida el manifiesto del checkout backend;
2. opcionalmente aplica la política DevOps del proveedor para reproducir nombres y decisiones por
   cola del ambiente `dev`;
3. genera bajo `local/generated/` un Docker Compose y la configuración declarativa del proveedor;
4. inicia el broker y espera que la topología esté disponible;
5. genera en el backend `.hexagon/local-messaging-bindings.json`, conforme al contrato
   `LocalMessagingBindings` v1 y separado por workload;
6. el AppHost valida producto, proveedor y workloads, e inyecta variables; no aprovisiona recursos.

Los artefactos generados y las credenciales exclusivamente locales se ignoran en Git. Los secretos
de ambientes desplegados no usan este archivo y siguen llegando mediante identidad o el gestor de
secretos correspondiente.

Las fixtures de pruebas integrales pueden crear brokers y entidades desechables para aislar cada
prueba. No son infraestructura de ejecución ni una segunda topología operativa.

## Consecuencias

- Backend y DevOps conservan una frontera única en local y en despliegues.
- Cambiar de proveedor no añade SDKs o assets del broker al AppHost.
- Crear o modificar una cola requiere actualizar el manifiesto backend y la política DevOps; no se
  programa creación de infraestructura en runtime.
- El desarrollador inicia mensajería desde la instancia DevOps antes de ejecutar el AppHost.
- La fase no añade pipelines, recursos cloud ni decisiones de plataforma de cómputo.
