# 0018. Candidatos verificados y activación tras mantenimiento

- Estado: Aceptado
- Fecha: 2026-11-10

## Contexto

9B genera OCI y SPA verificables. El ciclo efímero ya crea hosting y mensajería, pero un root
Verified no acredita que haya imágenes en ACR ni que la base de datos esté preparada. Los jobs
de Container Apps se definen con Terraform; su arranque es una operación adicional que puede
quedar aceptada aunque el runner pierda la respuesta.

## Decisión

Se añade ApplicationDelivery v1 para fijar run ID, intento, artifact ID y SHA-256 del ZIP por
componente. La selección se revisa en main y queda ligada al release. Solo se consumen candidatos
de la CI conocida en main con conclusión success, commit/repositorio exactos y contenido validado.
Se copian manifiesto y blobs originales mediante Registry v2, con tokens de la identidad aislada
en memoria y sin reconstruir imágenes ni publicar paquetes del core.

Un workflow manual comparte Environment, concurrencia y lease con el ciclo de infraestructura.
La habilitación de mantenimiento y la activación usan planes Terraform distintos, revisados por
hash en despachos separados. Migraciones preceden al bootstrap de acceso; ambos deben finalizar
Succeeded con la configuración esperada antes del rollout de API/Workers. No basta el exit code
del comando que inicia un job.

Un journal separado, ligado al release/destino/IaC y protegido por CAS, conserva evidencia. Cada
job guarda su intención antes del POST y añade un marcador al template. Tras una interrupción
solo se adopta la ejecución exacta; una solicitud ambigua no se reenvía automáticamente. Cambiar
imágenes, configuración o contexto de mensajería invalida la evidencia de mantenimiento.

## Consecuencias

El bootstrap sigue separado del despliegue, y Terraform mantiene la responsabilidad sobre recursos
y permisos. La lectura de artefactos privados requiere Actions: read, distinta del acceso al core
y a fuentes. La evolución a GitHub App mantiene su recomendación.

La recuperación conservadora puede exigir intervención o una nueva instancia efímera cuando un
intento no es demostrable. Los candidatos tienen retención limitada; no se selecciona latest como
recuperación. La retirada permanece independiente de artefactos y de este journal.

Este bloque verifica el candidato SPA, pero su publicación, salud, recorrido integral y limpieza
automática permanecen pendientes. applicationVerified sigue false. Las pruebas locales y HTTP no
acreditan una ejecución cloud ni cierran 9C.
