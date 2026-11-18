# Registro de cambios

## Sin publicar

- Fija en el descriptor dev las aplicaciones con Settings (PLAT-01): frontend `806f87b` y backend
  `59bfa47`, con hashes verificados desde GitHub. Añade la guía `README-settings.md`. No crea
  infraestructura ni concede operaciones UMA: se conceden explícitamente en la administración Auth.

- Adopta preparación/entrega Auth UMA desde DevOps `a940b5c` mediante la fábrica. El descriptor dev
  fija los merges frontend/backend y sus contratos de aceptación con hashes verificados desde
  GitHub. Incluye guía de adopción; no configura credenciales ni crea infraestructura cloud.

- Sincronización desde DevOps `c150168` mediante la fábrica. Incorpora Floci y sus límites
  de cobertura, las correcciones de bindings y salud AWS, las pruebas y el control de recursos locales.
  El destino de Reference es Azure en `dev`. La validación cloud requiere su orden expresa.

- Se retira `docs/continuidad/`: es documentación interna de la plataforma y no corresponde a un
  repositorio público. Las sincronizaciones desde la plantilla no la vuelven a traer.
- Instancia pública de DevOps para Reference; frontend, backend y core privados.
- Bootstrap Azure con destino autorizado, estado privado y una sola identidad de despliegue para `dev`.
- Se retiraron los grupos, identidades, permisos, contenedores y Environments de `staging` y `prod`
  creados inicialmente; la definición ahora selecciona solo `dev`.
- Grupo dev-auth reservado para la identidad de referencia, sin aprovisionamiento desde aplicaciones.
- Corrección heredada de las pruebas de bootstrap para nombres de producto distintos de Template.
