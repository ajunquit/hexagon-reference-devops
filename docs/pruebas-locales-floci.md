# Pruebas locales con Floci

Floci es la herramienta oficial de Hexagon para probar y desplegar en local
([ADR 0026](adr/0026-floci-como-plataforma-local.md)). Mientras estén suspendidos los despliegues
reales, por falta de minutos de GitHub Actions, estas pruebas son la garantía de la plataforma.

Cada nube trae su runner `tests/Invoke-FlociRoots<Nube>.ps1` y su guía
(`pruebas-locales-floci-<nube>.md`), con sus pruebas, sustitutos y derivas. Esta guía describe lo
común. Los helpers compartidos están en `tests/FlociSupport.ps1`.

Ninguna corre en la CI: se ejecutan en local antes de abrir un PR que toque lo que prueban, y el
resultado va en el PR.

## Requisitos

- Docker en marcha. La prueba descarga la imagen de Floci que fija el runner de la nube y
  `hashicorp/terraform:1.17.1`.
- Unos 4 GB de memoria libres para el emulador y los contenedores que levanta.
- Acceso a internet la primera vez, para las imágenes y los proveedores de Terraform. Los
  proveedores quedan en el volumen Docker `hexagon-terraform-plugins` y se reutilizan.

No necesita credenciales de ninguna nube y no toca ninguna cuenta real.

## Cómo funciona

1. **Emulador.** Arranca Floci en `127.0.0.1`, en una red Docker propia de la prueba y con el
   socket de Docker montado (decisión del dueño), para que los servicios que Floci respalda con
   contenedores reales funcionen.
2. **Copia temporal.** Copia `terraform/` sin los directorios `.terraform` a
   `artifacts/floci-<nube>-<id>/`, con backend local. El estado real nunca se toca.
3. **Terraform en Linux.** Ejecuta la imagen oficial de Terraform dentro del espacio de red del
   emulador, con la configuración que el emulador de la nube requiere.
4. **Recorrido.** Estado inicial; después `maintenance_jobs_enabled` y
   `application_rollout_enabled`; plan de convergencia; destrucción, que corre aunque falle un
   `apply`, y comprobación de que el estado queda vacío.
5. **Limpieza.** Elimina el emulador, los contenedores que creó y su red. La copia temporal queda
   para revisarla; no contiene credenciales.

Resultado: cada paso aparece como `Passed`, `Failed`, `Applied` (sustituto) o `Drift`. El script
termina con error si algún paso falla.

## Sustitutos y derivas

Floci no tiene todos los servicios que usan los módulos. Cuando falta uno, la copia temporal lo
sustituye. Cada sustituto busca el texto exacto del módulo y detiene la prueba si no lo encuentra,
para que un cambio del módulo obligue a revisarlo.

El plan de convergencia puede mostrar cambios que solo existen en el emulador. La prueba los marca
como `Drift (emulator fidelity gap)` y no falla. Una deriva en otro recurso que los listados por la
guía de la nube es una señal a investigar.

## Límites

- **No acredita la nube.** Floci no reproduce la red de la nube, los límites de los servicios,
  todos los permisos ni los tiempos reales. Con los despliegues reales reanudados, el primer
  despliegue en cada nube sigue siendo obligatorio.

## Actualizar Floci

1. Elegir una versión publicada hace al menos dos semanas.
2. Cambiarla en el runner de la nube, en su módulo de mensajería local y en las pruebas .NET que la
   fijan, en DevOps, el core y la plantilla ML.
3. Ejecutar las pruebas de la guía de la nube y retirar los sustitutos que la versión nueva ya no
   necesite.
4. Anotar el resultado en el PR.
