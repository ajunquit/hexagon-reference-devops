# 0006. Topología de AWS SNS/SQS con redrive por cola

- **Estado:** Aceptada
- **Fecha:** 2026-11-08

## Contexto

AWS no comparte la semántica de Azure Service Bus. SNS publica y filtra; cada Consumer recibe desde
su propia cola SQS. Una DLQ solo existe cuando la cola origen tiene una redrive policy. El equipo
necesita decidir esa política por cola, sin hacer que la API o el Worker creen recursos.

El adaptador AWS conserva el cuerpo y los atributos canónicos únicamente cuando la suscripción usa
Raw Message Delivery. También necesita el atributo `EventType` para deserializar y para aplicar el
routing declarado por el backend.

## Decisión

- Crear un topic SNS estándar por destino y una cola SQS estándar por Consumer.
- Habilitar Raw Message Delivery y filtrar `include` por el atributo `EventType`; `all` no lleva
  filtro.
- Restringir cada policy SQS al topic que la alimenta.
- Exigir una decisión `redrive.enabled` independiente por Consumer.
- Cuando se habilita, crear una DLQ dedicada, configurar `maxReceiveCount` y permitir redrive solo
  desde la cola origen. Su retención es mayor que la retención de origen.
- Cuando se deshabilita, no crear DLQ ni redrive policy.
- Cifrar topics con una clave KMS del producto y rotación; cifrar colas con SQS-managed SSE.
- Adjuntar permisos mínimos a IAM roles existentes y distintos por workload; el runtime no recibe
  administración ni acceso a la DLQ.
- No soportar FIFO mientras el contrato backend no publique `MessageGroupId`.

## Consecuencias

- Cada equipo puede elegir DLQ por cola sin cambiar el backend.
- Un mensaje fallido sin redrive permanece sujeto a retención y reintentos de la cola; no se mueve
  a otra entidad automáticamente.
- Activar o desactivar redrive es un cambio de política DevOps revisable por ambiente.
- Los filtros tardan en converger según la consistencia eventual de SNS; una promoción debe
  comprobarlos antes de enviar tráfico.
- La operación de DLQ, alertas y reproducción sigue reservada para la fase 8.
