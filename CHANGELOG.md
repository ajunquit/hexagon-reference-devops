# Registro de cambios

## Sin publicar

- Instancia pública de DevOps para Reference; frontend, backend y core privados.
- Bootstrap Azure con destino autorizado, estado privado y una sola identidad de despliegue para `dev`.
- Se retiraron los grupos, identidades, permisos, contenedores y Environments de `staging` y `prod`
  creados inicialmente; la definición ahora selecciona solo `dev`.
- Grupo dev-auth reservado para la identidad de referencia, sin aprovisionamiento desde aplicaciones.
- Corrección heredada de las pruebas de bootstrap para nombres de producto distintos de Template.
