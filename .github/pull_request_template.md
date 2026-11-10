## Qué cambia y por qué

<!-- Describe el resultado y la decisión que implementa. -->

## Cómo se probó

- [ ] `pwsh ./scripts/Test-Repository.ps1`
- [ ] Los descriptores modificados se verificaron con `-VerifySources`.
- [ ] No se ejecutó `apply` contra un ambiente compartido desde una estación local.

## Límites y seguridad

- [ ] No contiene secretos, estado, planes ni bindings generados.
- [ ] No traslada aprovisionamiento al runtime de una aplicación.
- [ ] Mantiene estados separados por producto y ambiente.
- [ ] El cambio pertenece a la fase autorizada de la ruta.

## Definition of Done

<!-- Enumera la evidencia funcional y operativa de esta fase. -->
