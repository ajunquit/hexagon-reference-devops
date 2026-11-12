# 0022 — Un DevOps para monolitos simples y modulares

- Estado: aceptado
- Fecha: 2026-11-11
- Sustituye: únicamente la obligatoriedad de monolito modular inicial de ADR 0004.

## Contexto

El perfil backend mx necesita una API, PostgreSQL y Keycloak, sin broker ni Workers. Duplicar
la plantilla DevOps por mx/ml repetiría hosting, bootstrap, identidad y operación. La capacidad
de mensajería debe ser explícita, sin inferirse del sufijo del repositorio.

## Decisión

Se mantiene `hexagon-template-devops` y una instancia por producto. Se admiten monolito simple
mx y modular ml; ms permanece futura y requiere una necesidad demostrada. Los contratos fijados
por commit y hash determinan las capacidades, no el nombre del repositorio.

Para un backend sin mensajería, el descriptor fija solo hosting mediante la opción explícita
`WithoutBackendMessaging`, que exige `IncludeBackendHosting`. El exportador admite solo workloads
API en este perfil y materializa `messaging_enabled=false`. No crea un root messaging vacío ni
simula un broker. Su inventario contiene hosting y rechaza un root messaging inesperado.

El bootstrap SQL recibe `messagingEnabled=false`, concede únicamente hexagon_app y retira una
membresía outbox anterior si existe. No necesita que el rol outbox exista. La lectura de directorio
y la denegación de acceso a Keycloak se conservan. Un binario antiguo rechaza el campo nuevo antes
de escribir; se necesita un candidato de operaciones actualizado.

## Consecuencias

El perfil actual con mensajería conserva valores predeterminados y comprobaciones. La ausencia
de mensajería participa del hash del mantenimiento y debe coincidir con el inventario. No se
eliminan brokers, mensajes o estados existentes automáticamente al cambiar de perfil.

La referencia 9C modular y su aceptación con Worker mantienen su recorrido; esta entrega no
ejecuta cloud ni acredita aceptación Azure para mx. El Auth administrativo compartido llega del
core; DevOps sigue administrando recursos y bindings, sin duplicar los datos de usuarios o roles.
