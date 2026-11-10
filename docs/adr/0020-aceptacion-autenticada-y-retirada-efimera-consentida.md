# 0020. Aceptación autenticada y retirada efímera consentida

- Estado: Aceptado; implementación y pruebas de protocolo, ejecución Azure pendiente
- Fecha: 2026-11-10
- Amplía: ADR 0017, 0018 y 0019; no sustituye sus protecciones del ciclo manual

## Contexto

Publicar la SPA y observar réplicas saludables no demuestra la sesión OIDC, una operación por
tenant ni su reacción asíncrona. El recorrido necesita datos iniciales aislados y retirar después
la instancia, incluso si falla la prueba. Un `finally` que aplique cualquier plan destruiría
recursos sin una revisión acotada; revisar dos planes de destrucción simultáneos tampoco respeta
las dependencias ni las revisiones del inventario.

## Decisión

Las aplicaciones declaran `AcceptanceRequirements` v1, perfil `tenant-event-reaction/v1`, con
recurso/consulta y ruta/selectores lógicos. CI incorpora sus hashes. DevOps valida sus propios
esquemas, el commit y la release; ningún manifiesto proporciona comandos libres o credenciales.
La primera referencia de identidad conduce la pantalla Keycloak con Code/PKCE S256.

Terraform declara un job opcional de carga inicial, con imagen API por digest e identidad de
mantenimiento. El backend ejecuta `--seed-acceptance-only`, prepara dos tenants de esa instancia
y no escucha HTTP. La plataforma proporciona previamente la identidad OIDC de prueba.

Application Delivery añade dos despachos distintos: `PrepareAcceptance` genera un consentimiento
inmutable de los IDs, direcciones Terraform, tipos, lineage/serial y bindings exactos actuales;
una persona revisa ese objeto privado. `Acceptance` exige su hash y la confirmación
`TEST AND CLEANUP producto ambiente instancia`. Caduca a las 24 horas. Solo se admite una
instancia Ephemeral dev/staging con DeleteEphemeral, ambos roots Verified y sin planes pendientes.

Esta es una excepción **limitada a ese conjunto previamente revisado**: tras la prueba, el motor
prepara cada plan destroy en orden inverso, exige exclusivamente delete/no-op sobre el conjunto
exacto consentido y conserva binario/JSON/hash antes de aplicar. No admite altas, updates,
reemplazos, imports, IDs nuevos, omisiones ni cambios de inputs, fuentes, ámbito o estado.
Conserva lease/CAS, quiescencia, observación y checkpoints del motor. Los planes manuales de
Genesis/Apocalypse y la infraestructura persistente mantienen Prepare/Apply separados.

La intención se guarda antes de ejecutar el job. La evidencia del recorrido se escribe antes de
retirar datos, también si falla. Si no puede custodiarse, no se borra. El resultado distingue
recorrido y limpieza; un fallo de retirada no puede figurar como éxito. Una interrupción o fallo
parcial conserva inventario y se recupera con Apocalypse y nuevos planes revisados. No se rompen
leases ni se reintenta a ciegas un POST de mantenimiento o una prueba interrumpida.

## Consecuencias y límites

No se guardan tokens, estados de sesión, HAR, trazas, capturas o vídeo del navegador. Las
credenciales solo llegan al proceso de aceptación y a Hexagon Auth. Se comprueba el Bearer de la
petición real de la UI y la confirmación persistida; el segundo tenant tiene pertenencia válida,
por lo que su 404 comprueba aislamiento de filas.

La limpieza preserva bootstrap, identidades de despliegue, grupos reservados, estado y evidencia.
Un corte del runner o cancelación forzada puede impedir `finally`: requiere recuperación manual,
sin prometer eliminación garantizada ante fallos de la plataforma. `applicationVerified` del
inventario permanece false: una prueba temporal seguida de destrucción no acredita disponibilidad.
Pruebas Chromium con endpoints simulados y pruebas del motor no acreditan Azure ni cierran 9C.
