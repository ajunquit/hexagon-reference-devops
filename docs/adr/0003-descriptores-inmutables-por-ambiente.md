# 0003. Descriptores inmutables por ambiente

- **Estado:** Aceptada
- **Fecha:** 2026-11-08

## Contexto

Frontend y backend son dueños de contratos diferentes. DevOps necesita agregarlos para un ambiente
sin leer una rama mutable, copiar sus contenidos ni convertir IaC en dueño de esos manifiestos.

Una referencia solo por tag o rama no demuestra qué contenido se validó. Una URL a `main` puede
cambiar entre el plan y el despliegue.

## Decisión

- Cada ambiente mantiene un `ProductEnvironment` v1.
- Cada componente fija repositorio, commit Git completo, ruta y `SHA-256` de cada manifiesto.
- El generador descarga el manifiesto y su esquema desde ese mismo commit, los valida y comprueba su
  identidad antes de escribir el descriptor.
- La verificación remota se repite antes de planificar infraestructura.
- Los bindings y outputs de IaC no se escriben en el descriptor ni vuelven a las aplicaciones.

## Consecuencias

- Un plan puede reproducir exactamente los requisitos que consumió.
- Promover consiste en revisar un cambio explícito de commits y resúmenes.
- Repositorios privados requieren autenticación de solo lectura para resolver y validar contratos.
- Cualquier versión o tipo desconocido falla de forma cerrada antes de crear recursos.
