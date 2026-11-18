# Settings en la entrega dev

El descriptor fija aplicaciones con configuración funcional regional y preferencias propias.
Settings comparte la base PostgreSQL y Keycloak existentes; su esquema se crea mediante una
migración del backend con la identidad de mantenimiento. No requiere otro recurso de infraestructura.

La secuencia existente prepara migraciones y el inventario UMA antes del rollout. Revisar y
conceder explícitamente las operaciones Settings en Keycloak: el aprovisionamiento agrega recursos
y conserva asignaciones previas. El frontend usa capacidades; backend y RLS verifican cada petición.
El historial/vigencia y las preferencias pertenecen a los datos del producto, no al estado Terraform.

Las operaciones GetSettings, SaveSetting, GetSettingHistory y sus equivalentes GetMySettings,
SaveMySetting, GetMySettingHistory se identifican por nombre y método bajo el prefijo Settings.
Usar el contrato backend vigente y la administración Auth; no escribir permisos por endpoint ni
introducir valores funcionales, contraseñas o tokens en el descriptor.

Este cambio de revisiones no equivale a despliegue. El flujo conserva candidatos CI, hashes,
artefactos OCI/bundle y mantenimiento con identidad separada antes del runtime. Verificar las
fuentes del descriptor antes de activar la entrega. La referencia mantiene únicamente dev.
