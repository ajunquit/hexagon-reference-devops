# ADR 0014: bootstrap ejecutable con aislamiento por ambiente

- Estado: aceptada
- Fecha: 2026-11-09
- Amplía: [ADR 0013](0013-bootstrap-de-plataformas-declarativo.md)

## Contexto

Validar y planificar no crea la plataforma ni acredita federación. El laboratorio movieops aporta
la secuencia, pero una identidad común y claves distintas dentro de un contenedor no aíslan los
ambientes. También debe existir un único propietario Terraform por recurso y recuperación ante fallos.

## Decisión

El comando de bootstrap añade Prepare, Apply, Migrate y Verify. Prepare materializa un plan por
etapa; Apply exige el SHA-256 de su registro revisado, verifica archivos, código, YAML, repositorio,
subject y vigencia de 24 horas y repite el preflight común. No ejecuta planes destructivos ni comandos
arbitrarios. El runner conserva un lock local; Terraform conserva el lock remoto. No se ejecuta
el bootstrap automáticamente desde un PR ni como parte de Genesis.

Terraform es propietario del estado, contenedores, grupos de ambiente, identidades y RBAC.
PowerShell configura GitHub a través de su API. Cada ambiente obtiene una identidad administrada
propia, federada exclusivamente con su GitHub Environment y la audiencia Azure esperada; no se
crean aplicaciones con contraseñas/certificados. Contributor queda limitado a los grupos del ambiente.
La delegación RBAC se limita a ServicePrincipal y a AcrPull, Key Vault Secrets User y los roles
Sender/Receiver de Service Bus, con condición tanto para escritura como para borrado.

Cada ambiente usa un contenedor de estado distinto, sin acceso al contenedor de bootstrap ni al
de otro ambiente. El bootstrap conserva sus estados State/Access separados dentro de su contenedor.
Los grupos de ambiente pertenecen al bootstrap y sobreviven a Apocalypse; los roots de hosting y
mensajería los consultan como datos y administran sus recursos interiores. No hay doble ownership.

La migración usa state push sin force, con locking y comprobación de lineage, serial y recursos.
Solo elimina las copias locales conocidas después de contrastar el estado remoto. Un fallo conserva
las copias para retomar. No adopta estados remotos ajenos ni importa infraestructura implícitamente.

GitHub se reconcilia por ambiente: revisores con acceso, prohibición de autoaprobación donde hay
revisores, bypass administrativo deshabilitado, solo la rama main y las tres variables Azure.
Una capacidad no disponible provoca bloqueo; no se degrada la protección de producción. Las políticas
de rama ajenas y reglas de protección no reconocidas requieren resolución explícita.

Verify contrasta planes Terraform sin cambios, federación exacta, roles directos/heredados observados
y configuración GitHub. Solo afirma Verified si también se acredita el workflow de diagnóstico
concluido con success, sus tres jobs y pasos obligatorios, el commit local y el hash del YAML.
Sin ese diagnóstico permanece Unverified. El diagnóstico es manual, solo main, usa los Environments
y comprueba acceso propio y rechazo 403 entre ambientes y al contenedor de bootstrap, sin crear datos.

## Consecuencias

Se implementan las cinco correcciones de la auditoría mediante mecanismos y pruebas automatizadas;
la evidencia cloud de un producto exige ejecutar el recorrido con sus propios valores. CI con dobles
y mocks no acredita un despliegue real ni cierra 9C. Azure DevOps/WIF sigue siendo un adaptador futuro;
no se presenta como disponible.

Los despliegues anteriores que posean sus grupos deben migrar ownership de forma revisada antes
de adoptar esta versión. La guía describe las precondiciones y límites. El bootstrap y sus grupos
persistentes quedan fuera de Genesis/Apocalypse; esto no implementa aún esos workflows.
