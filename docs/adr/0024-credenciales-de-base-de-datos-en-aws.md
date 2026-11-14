# ADR 0024: credenciales de base de datos en AWS

- Estado: aceptada
- Fecha: 2026-11-12
- Sustituye en parte a: [ADR 0023](0023-referencia-de-hosting-en-aws.md), en el **orden** de las
  tareas de mantenimiento y en **quién crea** los usuarios de base de datos.

## Contexto

La [ADR 0023](0023-referencia-de-hosting-en-aws.md) decidió contraseñas por workload en Secrets
Manager: Terraform crea los secretos vacíos y una tarea los rellena. También fijó el orden
`database-access`, migraciones y base de Keycloak. Al implementar esa tarea aparecieron dos
restricciones:

- En Azure, las migraciones van **antes** que `database-access`: crean los roles `hexagon_app` y
  `hexagon_outbox` que `database-access` concede después. En AWS, además, las migraciones
  necesitan su propia cadena de conexión con contraseña, porque en producción el backend solo deja
  de usar la credencial de Azure si la cadena incluye la contraseña.
- RDS no da `SUPERUSER` a su usuario maestro, y su contraseña rota sola. Por eso no puede ser el
  usuario de las migraciones: no se debe copiar en otra cadena de conexión.

El dueño decidió (2026-11-12) que **ningún operador introduce a mano** credenciales de base de datos,
en ningún ambiente, y que una credencial existente **se conserva**. Solo rota con su orden expresa.

## Decisión

- **Generadas por la tarea, nunca por una persona:** contraseñas aleatorias de 40 caracteres
  alfanuméricos con un generador criptográfico. No aparecen en logs, planes, estado ni descriptores.
- **Conservar:** si el secreto ya tiene valor, la tarea reutiliza su contraseña tras comprobar que
  pertenece a ese usuario, ese host y esa base de datos. Solo un secreto vacío recibe una contraseña
  nueva. Repetir una tarea no rota nada. La rotación será una operación aparte y explícita, que se
  implementa cuando el dueño la ordene.
- **Usuario de mantenimiento**, equivalente a la identidad de mantenimiento de Azure:
  - tiene `LOGIN`, `CREATEROLE` y `BYPASSRLS`, pero no es superusuario;
  - es **dueño de la base del producto** y ejecuta las migraciones.
  
  El usuario maestro de RDS solo lo crea y le transfiere la base. Para hacerlo se conecta a la base
  `postgres`, porque después ya no puede entrar en la del producto.
- **Orden de las tareas**, todas con `ecs:RunTask` y una sola vez por entrega:
  1. `database-credentials` (`--prepare-credentials`), con el usuario maestro: crea o conserva el
     usuario de mantenimiento; después, con ese usuario, un usuario sin privilegios por workload.
     Escribe sus cadenas de conexión.
  2. `migrations`, con el usuario de mantenimiento.
  3. `database-access`, con el usuario de mantenimiento: concede los roles de runtime con el mismo
     código que Azure.
  4. En dev con Keycloak integrado, `keycloak-database` (`--prepare-keycloak`), con el usuario de
     mantenimiento: el rol y el esquema de Keycloak, y la contraseña de su administrador inicial.
- **Cifrado en tránsito:** las cadenas de conexión usan `SSL Mode=Require`, igual que Keycloak. La
  CA de RDS no está en las imágenes de las aplicaciones; verificar la identidad del servidor exige
  incluirla.

## Consecuencias

- Desde PostgreSQL 16, un usuario que no es superusuario no puede mencionar `SUPERUSER`,
  `REPLICATION` ni `CREATEDB` en `ALTER ROLE` sin tener ese atributo. En AWS, esos atributos solo
  aparecen en `CREATE ROLE`. Azure conserva su sentencia.
- Las pruebas usan PostgreSQL 17 real, con un usuario maestro sin superusuario como el de RDS, y
  LocalStack para Secrets Manager. Que RDS permita al maestro conceder `BYPASSRLS` y transferir la
  base se comprueba en la validación real (D-9C-AWS).
- La tarea de mantenimiento lee y escribe solo los secretos de conexión y los de Keycloak.
