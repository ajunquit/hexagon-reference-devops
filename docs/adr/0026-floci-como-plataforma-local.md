# ADR 0026: Floci como plataforma local oficial y suspensión de los despliegues reales

- Estado: aceptada
- Fecha: 2026-11-14
- Decisión del dueño, en esta conversación con el agente, el 2026-11-14.
- Relacionada con: [ADR 0023](0023-referencia-de-hosting-en-aws.md), [ADR 0025](0025-ciclo-de-ambiente-en-aws.md)

## Contexto

Los minutos de GitHub Actions de la cuenta están agotados hasta diciembre de 2026. Mientras dure,
los workflows de Genesis, entrega y Apocalypse no pueden ejecutarse en los repositorios privados, y
un despliegue real a medias dejaría recursos con coste y sin dueño. A la vez, la plataforma necesita
seguir comprobando que su infraestructura y su entrega funcionan.

Para probar en local se evaluaron tres emuladores (2026-11-13 y 2026-11-14), aplicando y destruyendo
el root `hosting-aws` real:

| Emulador | Resultado |
| --- | --- |
| AWS Emulator (AWS) | Gratuito, pero cubre sobre todo el plano de control: no ejecuta contenedores ni bases de datos y no evalúa IAM. Se detuvo pronto, en la regla de salida por defecto de los grupos de seguridad y en el host de las etiquetas de S3. |
| LocalStack | Desde el 2026-03-23 exige cuenta y token. Su plan gratuito prohíbe el uso comercial y no incluye ECS, ECR, RDS, CloudFront, el balanceador ni Cloud Control; el plan que los incluye cuesta 39–45 USD al mes. |
| Floci | Licencia MIT, sin cuenta ni token. Cubre AWS (`floci`) y Azure (`floci-az`), y ejecuta como contenedores reales ECS, RDS, ECR y PostgreSQL. Creó todo el root `hosting-aws` salvo dos servicios que no tiene. |

## Decisión

1. **Floci es la herramienta oficial de Hexagon para probar y desplegar en local**, en AWS
   (`floci/floci`) y en Azure (`floci/floci-az`). No se usa AWS Emulator ni LocalStack: lo que
   dependía de ellos se retira o se migra a Floci.
2. **Se suspenden los despliegues reales en AWS y en Azure** (D-9C y D-9C-AWS) hasta que vuelva a
   haber minutos de Actions, previsto en diciembre de 2026. La suspensión solo la levanta una orden
   expresa del dueño; mientras tanto, la garantía de la plataforma es el despliegue local en Floci.
3. **Versiones exactas**, publicadas hace al menos dos semanas, como cualquier dependencia. Se suben
   a mano, en un PR, comprobando antes la prueba local. Hoy: `floci/floci:2.3.0`,
   `floci/floci-az:0.15.0` y `hashicorp/terraform:1.17.1`.
4. **Floci recibe el socket de Docker** (decisión del dueño), porque sin él no puede levantar los
   contenedores que respaldan ECS, RDS, ECR o PostgreSQL. Escucha solo en `127.0.0.1` y usa una red
   Docker propia de la prueba, que se elimina al terminar junto con los contenedores que creó.
5. **Terraform corre en su imagen oficial de Linux**, dentro del espacio de red del emulador: el
   mismo comportamiento en Windows, macOS y Linux, sin tocar el almacén de certificados del equipo.
6. **Los roots se prueban tal cual.** Solo cuando Floci no tiene un servicio, la copia temporal lo
   sustituye; cada sustituto se comprueba contra el texto del módulo, de modo que un cambio del
   módulo detiene la prueba en lugar de probar otra cosa. La lista vive en
   [pruebas locales con Floci](../pruebas-locales-floci.md) y cada sustituto tiene una condición
   para retirarlo.
7. **Lo local no acredita la nube.** Floci no reproduce la red de AWS o Azure, los límites de los
   servicios ni toda la evaluación de permisos. Cuando se levante la suspensión, el primer
   despliegue en cada nube sigue siendo obligatorio antes de dar un ambiente por operativo.

## Garantía local

"Funciona en local" significa, por incrementos y en este orden:

1. **Infraestructura:** los roots de hosting y de mensajería de cada nube se aplican, convergen y se
   destruyen en Floci sin dejar nada (`tests/Invoke-FlociRoots.ps1`).
2. **Mensajería local:** el entorno de desarrollo y las pruebas de integración de AWS SNS/SQS usan
   Floci en lugar de LocalStack, en DevOps, en el core y en la plantilla ML.
3. **Despliegue local completo:** el ciclo de ambiente y la entrega contra Floci: imágenes al
   registro del emulador, tareas de mantenimiento, servicios en marcha, SPA servida y aceptación.

Cada incremento cuenta solo con su prueba ejecutada y su resultado registrado en la continuidad.

## Consecuencias

- La CI no ejecuta Floci: la prueba es local y la ejecuta quien cambia la infraestructura, con su
  resultado en el PR. Así no consume minutos.
- Se elimina `tests/Invoke-AwsEmulatorRoots.ps1` y su documentación.
- Las brechas de Floci se piden al proyecto y se retira el sustituto en cuanto una versión elegible
  las cubra.
- Si Floci deja de mantenerse o cambia de licencia, se revisa esta decisión: la prueba depende de
  la API de AWS y de Azure, no de Floci, y otro emulador podría ocupar su lugar.
