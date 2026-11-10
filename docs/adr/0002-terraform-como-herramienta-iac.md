# 0002. Terraform como herramienta de IaC

- **Estado:** Aceptada
- **Fecha:** 2026-11-08

## Contexto

La plantilla debe aprovisionar infraestructura de Azure, AWS, RabbitMQ y ambientes locales de forma
reproducible. El equipo ya usa Terraform en `movieops` y necesita una única herramienta, lenguaje,
modelo de estado y operación para todos los productos.

La selección de herramienta IaC es una decisión de plataforma no negociable. Admitir Terraform,
OpenTofu o Pulumi indistintamente multiplicaría módulos, validaciones, documentación y procedimientos
de recuperación del estado.

Referencia: [documentación de Terraform](https://developer.hashicorp.com/terraform/docs).

## Decisión

- Usar exclusivamente Terraform y HCL para IaC.
- No ofrecer OpenTofu, Pulumi ni otro motor como variante de la plantilla.
- Separar módulos por proveedor y capacidad; no diseñar un módulo universal de mensajería.
- Separar el estado remoto por producto, ambiente y límite operativo.
- Crear el almacenamiento y bloqueo de estado mediante un bootstrap explícito que no dependa del
  backend que crea.
- Inyectar la configuración del backend y las credenciales fuera del repositorio.
- Fijar versiones de Terraform y de cada proveedor cuando se implemente el primer módulo en las
  fases 4 a 6.
- Automatizar `fmt`, `validate`, `plan` y `apply` en la fase 9, con identidad federada, revisión del
  plan y aprobación por ambiente.

## Consecuencias

- La estructura, experiencia y prácticas útiles de Terraform existentes en `movieops` se pueden
  reutilizar sin copiar sus decisiones de aplicación, proveedor o pipelines.
- Toda contribución necesita conocer Terraform y HCL; no se mantienen implementaciones paralelas.
- El estado, los planes y los valores sensibles nunca se confirman en Git.
- Una migración de herramienta requeriría un ADR que sustituya esta decisión, respaldo del estado y
  verificación de un plan sin cambios antes de aplicar.
