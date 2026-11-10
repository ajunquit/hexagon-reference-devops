# ADR 0010: primera referencia de hosting en Azure administrado

- Estado: aceptada
- Fecha: 2026-11-09

## Contexto

La fase 9A requiere una composición ejecutable de frontend y backend. El dueño eligió Azure
administrado como primera referencia. La decisión de Terraform y la elección independiente del
broker continúan vigentes; no se presupone Kubernetes.

## Decisión

- Angular se publica en Azure Static Web Apps, con HTTPS, fallback SPA y configuración pública
  materializada por DevOps. La SPA se compila una vez y se promueve por checksum.
- API y Workers se ejecutan como imágenes OCI en Azure Container Apps, con una identidad
  administrada distinta por workload. Solo la API tiene ingress público; las sondas usan el puerto
  interno de salud. Las imágenes se fijan por digest.
- Azure Container Registry distribuye las imágenes sin credenciales administrativas. PostgreSQL
  Flexible Server usa red privada, TLS y autenticación Entra; las credenciales no entran al estado.
- Las migraciones se ejecutan deliberadamente como un trabajo separado, antes de habilitar API y
  Workers. Su identidad tiene los privilegios de preparación de datos; los workloads no los heredan.
- Hexagon Auth es una dependencia de plataforma existente, basada en Keycloak. Este repositorio
  de producto referencia su autoridad y su cliente público: no crea una identidad paralela por
  producto ni captura contraseñas de personas.
- El frontend usa Authorization Code con PKCE contra Hexagon Auth para conectarse al backend real.
  La autenticación de demostración se conserva únicamente con la API simulada de desarrollo.
- DevOps verifica los contratos de ambas aplicaciones y materializa nombres, permisos, endpoints y
  configuración. El AppHost queda limitado al desarrollo local y no publica infraestructura Azure.

## Consecuencias

La composición de referencia no obliga a otros productos a elegir Azure ni al adaptador de
mensajería a usar Azure Service Bus. Las futuras composiciones de AWS u otras plataformas consumen
los mismos artefactos y contratos, con adaptadores e identidades propios.

Esta fase define y prueba la composición; su aplicación a un ambiente compartido requiere la
identidad, revisión y aprobación de despliegue de las subfases siguientes. No publica paquetes del
core. La autenticación real debe cumplir las ADR 0018 y 0024 de plataforma.
