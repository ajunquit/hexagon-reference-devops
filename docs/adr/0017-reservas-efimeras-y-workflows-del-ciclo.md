# ADR 0017: reservas efímeras y workflows del ciclo

- Estado: aceptada; implementación y pruebas de protocolo, ejecución cloud pendiente
- Fecha: 2026-11-10
- Amplía: [ADR 0012](0012-genesis-y-apocalypse-por-ambiente.md), [ADR 0016](0016-adaptador-azure-y-custodia-remota-del-inventario.md)

## Contexto

La identidad persistente de un ambiente no debe crear límites de RBAC ni concederse permisos de
bootstrap. El ciclo efímero necesita identidad, estado y grupos propios. También requiere revisar
el plan después de prepararlo y poder recuperar una baja sin depender del CI de aplicaciones.

## Decisión

El operador del bootstrap reserva la instancia mediante un root Terraform independiente, con plan
revisado y estado remoto propio. Se crean grupos, identidad administrada, federación exacta a un
Environment y contenedor por instancia; los permisos de despliegue se limitan a ellos. La reserva
conserva su ID run-ID-attempt entre despachos: representa la ejecución que originó la reserva,
no se regenera con cada reintento de Genesis/Apocalypse. Una identidad de workloads no puede
aprovisionar ni retirar esta base. Los límites de bootstrap sobreviven a la baja de workloads.

EphemeralEnvironment v1 declara inventario inicial, selección, TTL, federación y protecciones. La
definición resuelta vive en una ruta fija de main y se selecciona por SHA-256. Bootstrap devuelve
PreparedForDiagnostic hasta probar el aislamiento mediante la identidad federada real. Los probes
exigen 200 en ámbitos propios y 403 en grupos/containers protegidos; 404 no demuestra aislamiento.

Genesis y Apocalypse son workflows manuales con selector de ambiente/instancia/root. Prepare y
Apply son despachos separados, con hash de revisión y confirmación exacta, protecciones GitHub,
acciones fijadas, mismo grupo de concurrencia y lease/CAS. El motor impone hosting → messaging
y el orden inverso en la baja. Los principal IDs de mensajería se enlazan automáticamente desde
estado y ARM de hosting, generando snapshot y revisión nuevos, sin cambiar políticas físicas.

Quiesce es una operación explícita de Apocalypse para recursos efímeros inventariados. Invalida
planes anteriores, desactiva revisiones, detiene jobs Manual y deshabilita mensajería propia; luego
observa quiescencia con espera acotada. No modifica el inbox ni finge respaldo. La expiración bloquea
creación, no recuperación/baja. No se retiran locks/prevent_destroy ni se borran estados para forzar
una limpieza. Producción se bloquea hasta completar BackupRequired y adopción persistente en 9D.

## Consecuencias

La separación exige una reserva administrativa antes del ciclo de workloads; evita entregar a
pipelines de producto permisos para administrar identidades o toda la suscripción. Una reserva
parcial se recupera con un plan nuevo y su mismo estado. Su retiro administrativo requiere una
operación posterior de plataforma; no se confunde con Apocalypse ni con un recolector automático.

La operación manual usa varios despachos para conservar revisión real entre etapas. El siguiente
bloque conectará artefactos, aplicaciones y limpieza automática del recorrido efímero reutilizando
el motor. applicationVerified permanece false. Pruebas con dobles no acreditan una cuenta Azure,
aislamiento real ni cierre de 9C. La [guía operativa](../ciclo-efimero-azure.md) fija los comandos y límites.
