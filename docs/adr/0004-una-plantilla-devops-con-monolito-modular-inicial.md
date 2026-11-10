# 0004. Una plantilla DevOps con monolito modular inicial

- **Estado:** Aceptada
- **Fecha:** 2026-11-08

## Contexto

Hexagon tiene una plantilla backend de monolito modular (`hexagon-template-dotnet-ml`) y contempla
`hexagon-template-dotnet-ms` para servicios que se justifique extraer. Esto podría sugerir dos
plantillas DevOps, pero la infraestructura administra el producto completo: frontend, backend,
datos, mensajería, identidad, red, observabilidad y ambientes.

[BE-0003](https://github.com/ajunquit/hexagon-core-dotnet/blob/main/docs/adr/BE-0003-arquitectura-limpia-un-proyecto-por-capa.md)
adopta el monolito modular y prepara cada módulo para una posible separación. El
[roadmap de Clean Architecture](https://github.com/ajunquit/hexagon-core-dotnet/blob/main/docs/roadmap-clean-architecture-api-dotnet.md)
establece que los microservicios no se adoptan por defecto: se empieza por monolito o monolito
modular salvo necesidad demostrada.

Separar `hexagon-template-devops-ml` y `hexagon-template-devops-ms` duplicaría módulos, políticas y
validaciones. También obligaría a decidir cómo mover estados y recursos cuando un producto extraiga
su primer servicio, aunque el frontend, la red, los datos y gran parte de la plataforma no cambien.

## Decisión

- Mantener una única plantilla `hexagon-template-devops`, sin sufijos `-ml` o `-ms`.
- Cada producto crea una única instancia `hexagon-<producto>-devops`.
- Todo producto comienza con un backend de monolito modular.
- Un microservicio se introduce solo ante una necesidad demostrada de dominio, equipo, aislamiento,
  despliegue o escalado independiente.
- La extracción evoluciona el mismo repositorio DevOps; no crea otra instancia ni copia el estado.
- Las unidades desplegables se comunicarán mediante contratos Aplicación–DevOps versionados. DevOps
  no inferirá la arquitectura por el nombre o la tecnología del repositorio.
- No se crean composiciones, módulos ni pipelines específicos para microservicios hasta que un caso
  real los necesite.

## Consecuencias

- La infraestructura mantiene continuidad durante la evolución arquitectónica del producto.
- Los módulos Terraform comunes, políticas y guardrails no se duplican entre variantes.
- Extraer un servicio exige ampliar los contratos y la composición con migración y reversión
  explícitas, pero no renombrar el repositorio DevOps.
- `hexagon-template-dotnet-ms` puede servir como plantilla de código para un servicio extraído sin
  convertirse en una segunda plantilla de infraestructura.
