# Hosting Azure de referencia

Módulo de fase 9A: Container Apps para API/Workers, PostgreSQL 17 privado con Entra, ACR, Static Web
Apps, identidades separadas y jobs manuales de preparación de datos. No incluye Hexagon Auth ni
topología de mensajería; consume sus bindings.

Usa imágenes de ACR fijadas por digest y la política materializada desde contratos. El estado
inicial no crea aplicaciones ni jobs; después se habilitan jobs y finalmente workloads.
`terraform test` usa mocks y no aprovisiona recursos.

El grupo de recursos debe existir y pertenecer al bootstrap de plataformas. El módulo lo consulta
como dato; no lo administra ni lo retira. Una instalación anterior debe migrar ese ownership de
forma revisada, según [la guía](../../../../docs/bootstrap-plataformas.md#migración-y-recuperación).

La [guía de hosting](../../../../docs/hosting-azure.md) detalla contratos, orden de activación,
artefactos, configuración estática, permisos y comprobaciones pendientes de cloud.
