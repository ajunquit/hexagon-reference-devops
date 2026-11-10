# 0001. Una instancia DevOps por producto

- **Estado:** Aceptada
- **Fecha:** 2026-11-08

## Contexto

La plataforma necesita reutilizar mecanismos de infraestructura sin mezclar el estado, los
permisos y el ciclo de vida de productos distintos. Un repositorio central para todos los productos
ampliaría el radio de impacto y obligaría a coordinar promociones y acceso sin una relación técnica.

La plantilla debe poder evolucionar sin convertirse en la fuente de verdad de un producto real.

## Decisión

- `hexagon-template-devops` es una plantilla GitHub reutilizable.
- Cada producto crea una instancia, por ejemplo `hexagon-hr-devops`.
- La instancia administra un solo producto y mantiene estados separados para `dev`, `staging` y
  `prod`.
- Frontend y backend conservan sus manifiestos lógicos; la instancia DevOps fija los commits que
  consume y administra los recursos físicos.
- La infraestructura realmente compartida por varios productos pertenecerá a un futuro repositorio
  `hexagon-platform-devops` o equivalente, con estado y permisos propios.

## Consecuencias

- Los fallos, permisos, estados y promociones se aíslan por producto.
- La plantilla contiene mecanismos y ejemplos, pero no configuración ni estado real.
- Mejorar la plantilla no actualiza automáticamente las instancias; cada producto integra cambios
  mediante un PR revisado.
- Puede existir duplicación explícita de composición entre productos. Se extraerán módulos
  reutilizables cuando haya evidencia de estabilidad, no compartiendo estados.
