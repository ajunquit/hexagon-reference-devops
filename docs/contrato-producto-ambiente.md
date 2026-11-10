# Contrato `ProductEnvironment` v1

Versión vigente: `hexagon.ec/product-environment/v1`.

El descriptor agrega los contratos Aplicación–DevOps que se aplican a un producto y ambiente. No es
un manifiesto de recursos cloud ni sustituye los manifiestos de las aplicaciones.

## Ubicación

```text
products/<product>/environments/<environment>/descriptor.json
```

Los ambientes v1 son `dev`, `staging` y `prod`. El producto usa el patrón `hexagon-<nombre>`.

## Campos

| Campo | Regla |
| --- | --- |
| `apiVersion` | Exactamente `hexagon.ec/product-environment/v1` |
| `kind` | `ProductEnvironment` |
| `product` | Identificador estable que coincide con los manifiestos |
| `environment` | `dev`, `staging` o `prod` |
| `components[].name` | Identificador lógico único, como `web` o `backend` |
| `components[].repository` | Repositorio GitHub `owner/name` |
| `components[].commit` | SHA Git completo de 40 caracteres; nunca una rama mutable |
| `manifests[].path` | Ruta relativa segura dentro de ese commit |
| `manifests[].sha256` | Resumen de los bytes exactos validados y aplicados |

No admite campos adicionales. La unicidad de componentes y rutas se comprueba en el script porque
JSON Schema no expresa de forma portable esa relación.

## Integridad

`New-ProductEnvironmentDescriptor.ps1` no confía en el contenido por su ubicación. Descarga el
manifiesto y su esquema desde el mismo commit, valida la forma, compara `product` y `component`, y
solo entonces calcula el resumen.

`Test-ProductEnvironmentDescriptor.ps1 -VerifySources` repite esa verificación. Una diferencia
falla antes de planificar infraestructura. DevOps rechaza una versión o `kind` desconocidos; no
interpreta el contrato por aproximación.

## Separación de responsabilidades

El descriptor fija **qué necesidades lógicas** se aplican. Los siguientes datos permanecen en IaC
y configuración protegida del ambiente:

- nombres físicos, regiones, cuentas y suscripciones;
- SKU, capacidad, red, cifrado, retención y copias;
- DLQ/DLX, redrive, entregas máximas y alertas por cola o suscripción;
- identidades, credenciales y referencias a secretos;
- estado, planes y outputs sensibles.

Los bindings generados no se escriben de vuelta en los repositorios de aplicación ni en el
descriptor.

## Compatibilidad

La fase 9A añade `-IncludeBackendHosting` al generador para fijar también
`BackendHostingRequirements` v1. `ApplicationRelease` v1 registra aparte digests de imágenes y
checksum del bundle, preservando las fuentes de este descriptor. La [guía de hosting](hosting-azure.md)
explica la validación conjunta; los valores de los ejemplos no son desplegables.

- Un campo opcional compatible puede añadirse a v1.
- Renombrar un campo, cambiar su significado o volverlo obligatorio exige v2.
- Cambiar un manifiesto exige otro commit y otro `SHA-256`.
- Cambiar solo una política física no altera el contrato de la aplicación, pero sí su IaC revisada.
