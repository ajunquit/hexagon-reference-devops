# Pruebas locales con Floci en Azure

Completa la [guía común de Floci](pruebas-locales-floci.md) para Azure. El runner es
`tests/Invoke-FlociRootsAzure.ps1` y fija `floci/floci-az:0.15.0`.

## Qué se prueba

| Prueba | Comando | Qué demuestra |
| --- | --- | --- |
| Infraestructura | `pwsh ./tests/Invoke-FlociRootsAzure.ps1` | El root `hosting-azure` se aplica (estado inicial, y después mantenimiento y rollout), converge y se destruye sin dejar nada. |

Terraform confía en el certificado del emulador, porque el proveedor `azurerm` exige HTTPS. Floci AZ
respalda con contenedores reales el registro de ACR y PostgreSQL.

## Sustitutos

| Sustituto | Por qué | Se retira cuando |
| --- | --- | --- |
| PostgreSQL con administrador y contraseña locales | Floci AZ exige un administrador con contraseña; Hexagon usa solo Entra ID | Floci AZ admita servidores solo con Entra ID |
| Sin las asignaciones del rol `AcrPull` | Floci AZ 0.15.0 no tiene asignaciones de rol: su RBAC aún no está en una versión publicada | Una versión elegible de Floci AZ incluya RBAC |
| Sin el administrador Entra ID de la identidad de mantenimiento en PostgreSQL | Floci AZ no tiene administradores Entra en PostgreSQL | Floci AZ los implemente |
| Sin workspace de Log Analytics ni su vínculo con el entorno de Container Apps | El proveedor consulta los workspaces borrados antes de crear uno, y Floci AZ no tiene esa API | Floci AZ la implemente |
| Sin los jobs de Container Apps de mantenimiento (`maintenance_jobs` queda vacío) | Floci AZ tiene Container Apps pero no sus jobs | Floci AZ implemente `Microsoft.App/jobs` |
| Static Web Apps pasa a ser un valor fijo con el mismo id y nombre de host | Floci AZ no tiene Static Web Apps | Floci AZ la implemente |

## Derivas conocidas

| Deriva | Causa |
| --- | --- |
| `azurerm_postgresql_flexible_server` se reemplazaría: no devuelve `delegated_subnet_id`, `private_dns_zone_id` ni `public_network_access_enabled = false`; arrastra a su base de datos, al `database_bootstrap` y a la cadena de conexión de la API | Floci AZ no modela la red privada de PostgreSQL |
| `azurerm_container_registry`: `role_assignment_mode` | Floci AZ no devuelve el atributo |

## Límites

- **Lo sustituido no se prueba.** Static Web Apps, Log Analytics, la autenticación solo con Entra ID
  de PostgreSQL, las asignaciones de rol `AcrPull` y los jobs de mantenimiento quedan sin cubrir en
  local.
- **Cobertura parcial.** Floci AZ 0.15.0 ofrece Service Bus mediante la API de datos, pero carece de
  la API ARM de namespaces, jobs de Container Apps y RBAC. `-Roots Messaging` lo informa como
  `Not covered`, y no hay entrega completa local.
