---
name: hexagon-handoff
description: Cierra una sesión de trabajo de Hexagon y actualiza el relevo versionado, el estado y los pendientes con evidencia de Git y PR para que otro agente o modelo pueda continuar. Úsala al pedir cierre, checkpoint o traspaso; una consulta de estado no implica actualizar documentos.
---

# Hexagon Handoff

Deja un relevo legible sin memoria del proveedor ni acceso al chat anterior. Aplica el
[protocolo y la ficha](references/protocolo.md) antes de escribir el cierre.

1. Identifica objetivo, alcance y última instrucción del usuario. Lee AGENTS, las decisiones
   aplicables y el punto de continuidad indicado por el repositorio. Para la plataforma Hexagon,
   ese punto es `INICIO.md` del repositorio privado `hexagon-continuity`; clónalo o actualízalo
   aparte, sin cambiar la rama de otra sesión. No inventes actividad anterior si el
   chat o la evidencia no están disponibles.
2. Contrasta el cierre anterior con Git y GitHub de los repos afectados. El recolector opcional
   [collect_context.py](scripts/collect_context.py) recoge hechos sin leer diffs ni contenido de
   archivos: `python <skill>/scripts/collect_context.py --repo <ruta> --github`. Permite repetir
   `--repo`; usa `--output <archivo-nuevo-privado>` para guardar el resultado. Si no hay Python,
   GitHub CLI o acceso, usa herramientas equivalentes y marca qué no se pudo verificar.
3. Actualiza el checkpoint y pendientes autorizados; agrega una ficha histórica con fecha en
   `relevos/` de `hexagon-continuity`. Enlázala desde el estado.
   Cambia INICIO, AGENTS, guías, ADR o Vision solo si hay una novedad aprobada que corresponda a
   su ámbito. Conserva decisiones, excepciones, pausas y trabajo ajeno. No copies el chat entero.
4. Comprueba enlaces, ausencia de secretos, coherencia de estados y siguiente paso concreto.
   No marques integrado un PR abierto ni aprobados unos checks de otro HEAD. Si cambió el estado
   remoto durante el cierre, registra la observación con fecha: el documento es una fotografía.
5. Entrega según la orden del usuario y los AGENTS: commit/PR documental cuando corresponda,
   sin fusionar ni publicar código ajeno por ejecutar esta skill. Devuelve el enlace al cierre,
   archivos actualizados, PR, limitaciones y una orden copiable para el próximo agente.

El cierre puede registrar trabajo incompleto. Su ejecución no autoriza continuar el backlog,
desplegar, borrar recursos ni ampliar permisos. Una pausa vigente permanece hasta que el usuario
la revoque. Si falta acceso al contexto privado, prepara la parte local verificable y señala
el destino pendiente; no crees silenciosamente una segunda fuente de verdad ni publiques el
relevo privado en un repositorio público.
