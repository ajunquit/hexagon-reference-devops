# Preparación de Auth en dev

El descriptor fija los commits integrados del frontend y backend y los hashes de sus manifiestos.
El backend declara `identity.authorization: keycloak-uma`: la entrega debe bloquearse sin los
bindings y la preparación requeridos. No retirar ese requisito para saltar la comprobación.

## Antes de una entrega real

1. Confirmar el issuer/realm y el UUID del cliente API del destino, conservando las identidades
   existentes. No tomar el UUID o secretos del AppHost local como valores cloud.
2. Preparar una definición pública KeycloakAuthorization según
   [la guía](../../../../../docs/preparacion-auth-uma.md). Mantener el secreto delegado en el gestor
   del proveedor y entregar al operador el token de bootstrap solo por entorno.
3. Ejecutar Validate/Plan; revisar el destino y después Apply/Verify con la CLI de preparación.
   El operador crea los clientes/delegación. La API no recibe el token del operador.
4. Asociar al API los tres ajustes públicos `Auth__Authorization__{Product,ResourceServerId,ClientId}`
   y la referencia a `Auth__Authorization__ClientSecret`. Los Workers no reciben esa credencial.
5. Ejecutar Migrations → DatabaseAccess → Authorization con las imágenes fijadas por digest.
   Authorization ejecuta reconciliación/aprovisionamiento nativo antes del rollout. El runtime
   conserva su usuario SQL restringido. Respaldar SQL/Keycloak antes de la importación inicial.
6. Comprobar acceso, aislamiento, revocación y recuperación. Reaplicar la preparación conserva
   políticas y asignaciones de la aplicación. La identidad delegada no debe poder administrar
   otro cliente ni restablecer contraseñas.

Esta actualización distribuye y verifica código; no crea recursos cloud ni configura credenciales
del destino. La validación local no acredita un despliegue operativo.

## Validación local

El proveedor de mensajería se arranca desde esta instancia DevOps, y PostgreSQL/Keycloak desde el
AppHost del backend con un volumen desechable propio. Con los proyectos compilados, usar
`tests/Invoke-AuthLocalIntegration.ps1` según la guía. Recibe credenciales solo por entorno y
arranca una API Production con SQL restringido, sin heredar credenciales GitHub/cloud/bootstrap.
Al terminar, retirar el AppHost, la mensajería y únicamente el volumen creado para esa prueba.

El descriptor incluye los contratos de aceptación existentes de la referencia. Tras el seed de sus tenants ficticios, acceptance-authorization debe terminar antes de ejecutar la aceptación; no reutilizar como evidencia un job anterior al seed.
