# ADR 0011: CI por componente y artefactos verificables

- Estado: aceptada
- Fecha: 2026-11-09

## Contexto

9A define hosting y arranque. 9B necesita comprobar cada repositorio y producir artefactos
identificables sin introducir despliegues ni publicar nuevas versiones NuGet del core.

## Decisión

GitHub Actions ejecuta CI independiente en frontend, backend y DevOps, en PR a main, push a main y
ejecución manual. Las acciones se fijan por SHA completo; los jobs tienen permisos de lectura,
concurrencia y timeout. No usan pull_request_target, identidad cloud ni Terraform apply.

Cada aplicación construye también en PR, pero solo las ejecuciones de main conservan candidatos
desplegables. Sus archivos se suben una vez, con nombre que contiene commit, run ID y reintento.
Un PR no produce una entrega promovible. Las evidencias de pruebas se conservan por separado.

`ComponentBuild` v1 identifica producto/componente, repositorio/commit, manifiestos, dependencias y
artefactos. Una SPA se identifica por checksum del bundle y no incluye bindings físicos. Una
imagen se exporta en formato OCI, con checksum del archivo, digest del manifiesto y plataforma;
los blobs se verifican sin extraerlos. Estos hashes no son intercambiables.

Mientras el core no se publique, el backend fija su commit, usa su pack-local.ps1 en un feed
efímero y resuelve una versión exacta para esa ejecución. Registra SHA-256 de los paquetes, pero
no los publica ni los sube como artefacto. El acceso privado al código es solo Contents: read y
se entrega durante checkout, sin persistir credenciales para pasos posteriores.

## Consecuencias

La plantilla DevOps valida los contratos y artefactos descargados contra una identidad de fuente
esperada, sin confiar solo en el build.json recibido. El consumidor de 9C también deberá verificar
repositorio, workflow, rama, commit, run y resultado de GitHub antes de aceptar una entrega.
ComponentBuild no es una firma ni sustituye esa verificación de procedencia.

Las copias de Actions tienen retención limitada. En 9C/9D se trasladarán los artefactos verificados
a su distribución duradera y se compondrá ApplicationRelease, preservando los digests originales.
CI no crea identidades de despliegue ni aprovisiona Azure. Las credenciales de lectura que falten
se configuran como secretos del repositorio; no se reutiliza automáticamente una credencial local.
