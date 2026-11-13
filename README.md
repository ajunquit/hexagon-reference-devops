# Hexagon Reference — DevOps

Instancia aislada para validar el ciclo 9C de las plantillas Hexagon. Administra solamente
`hexagon-reference`, con backend monolítico modular, frontend estático y Azure Service Bus.
No despliega HR ni contiene información de negocio real.

- Región inicial: eastus2.
- El backend, el frontend y el core se mantienen en repositorios privados.

Este repositorio es público por autorización del propietario para usar GitHub Environments y
sus protecciones con GitHub Free. No se versionan secretos, estados, planes ni bundles privados.

## Preparación y ejecución

`.config/platform-bootstrap.yaml` declara únicamente `dev`: tres grupos para aplicación, Auth y
mensajería, una identidad de despliegue y su protección GitHub. El almacenamiento de Terraform
vive en un grupo aparte. Otros ambientes se añaden solo cuando el producto los necesita.

Usa los comandos de [bootstrap](docs/bootstrap-plataformas.md) y conserva su workspace privado en
`artifacts/`. Prepare/Apply se ejecutan por separado y cada Apply exige su hash revisado.
La [aceptación integral](docs/aceptacion-integral-azure.md) requiere una reserva efímera nueva,
candidatos de CI/main, Hexagon Auth por HTTPS y configuración exacta del cliente público.

Hexagon Auth todavía no existe: se incorporará una composición Keycloak/PostgreSQL para esta
referencia, provisionada desde DevOps. La API no lo aprovisiona. La ejecución completa y la
retirada del ambiente no están acreditadas hasta conservar las evidencias del recorrido real.

## Validación

`pwsh ./scripts/Test-Repository.ps1`; instala primero las dependencias de acceptance y Chromium
según AGENTS.md. Las pruebas heredadas del bootstrap incluyen el arreglo de la plantilla para
que los fixtures no dependan del nombre del producto. El lector operativo sigue rechazando
productos distintos de `.config/product.json`.
