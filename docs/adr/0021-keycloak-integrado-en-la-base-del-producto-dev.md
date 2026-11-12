# 0021 — Keycloak integrado en la base del producto en dev

- Estado: aceptado
- Fecha: 2026-11-11
- Complementa: ADR 0010 de hosting, ADR 0018 de entrega y ADR de plataforma 0036.

## Contexto

La modalidad inicial de identidad comparte una base PostgreSQL entre Keycloak y el backend,
con esquemas y credenciales separados. Desplegar otro servidor para identidad contradice esa
modalidad y aumenta los recursos de la referencia. El hosting existente solo admitía un emisor
externo y PostgreSQL con autenticación Entra exclusiva.

## Decisión

El root `hosting-azure` admite un perfil opcional `keycloak`, inicialmente limitado a `dev`.
Administra un solo servidor y una sola base de aplicación, el proceso Keycloak y sus bindings.
La modalidad con emisor externo conserva su configuración. Los contratos lógicos de backend
y frontend no describen servidores, esquemas SQL ni secretos físicos.

API, Workers y mantenimiento conservan sus identidades Entra. Keycloak usa un rol SQL propio,
sin membresías ni privilegios administrativos, dueño únicamente de `keycloak`. Se habilita
autenticación dual del servidor para esta conexión. La contraseña administrativa que exige el
proveedor AzureRM entra mediante lectura **ephemeral** de Key Vault y un argumento **write-only**;
Keycloak y los jobs no la reciben. Los otros dos secretos son la contraseña SQL de Keycloak y
la contraseña de su administrador de arranque. Los tres se fijan por versión y no se guardan
sus valores en inputs, planes ni estado.

La entrega sigue preparación SQL → activación revisada de Keycloak → configuración del realm →
migraciones Hexagon → permisos runtime → activación del backend. No se ejecuta SQL desde el
host HTTP ni desde Terraform. El job SQL usa el artefacto de operaciones, un propósito explícito
y el journal de intentos existente. Antes de las migraciones se comprueba la aplicación real,
su revisión, imagen, identidad, referencias a secretos y descubrimiento OIDC del realm con S256.

Todo pertenece al mismo root e inventario. La quiescencia incluye Keycloak y los jobs antes de
retirar el almacenamiento. Este perfil no permite conservar identidad mientras se elimina su
base compartida. Una identidad persistente o central requiere otro alcance y una migración.

## Consecuencias y límites

Se reduce el número de servidores y se mantienen credenciales distintas. Los esquemas comparten
capacidad, fallos y recuperación de la base. No se ofrece escalado independiente ni HA de Keycloak:
la referencia usa una réplica y caché local. Producción requiere otra decisión de operación.

La preparación del vault y la carga de secretos pertenecen al operador/bootstrap, fuera del
estado efímero. Terraform no los crea ni captura sus valores. El operador debe autorizar lectura
del secreto administrativo antes del plan. No se amplían automáticamente permisos de despliegue.

Esta implementación no agrega el módulo Auth al backend, no configura automáticamente realm,
usuarios o clientes, y no acredita un despliegue Azure ni el cierre de 9C. El procedimiento y
las pruebas se documentan en [Auth y base compartida](../auth-y-base-compartida.md).
