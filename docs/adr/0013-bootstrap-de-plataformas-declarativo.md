# ADR 0013: bootstrap de plataformas declarativo

- Estado: aceptada; primer bloque de validación/plan implementado
- Fecha: 2026-11-09

## Contexto

Antes de Genesis se necesitan estado remoto, identidad de automatización y configuración de CI.
La carpeta scripts de movieops demuestra pasos independientes con coordinador y auditoría. Sus
defaults y permisos de laboratorio requieren adaptación para una plantilla con varios productos.

## Decisión

Una definición YAML versionada de la instancia DevOps declarará producto, repositorio, cloud,
identificadores, estado y ambientes sin secretos ni comandos libres. PowerShell coordina; Terraform
conserva la propiedad de los recursos cloud. La primera combinación es GitHub Actions → Azure.
Una identidad por ambiente y estados separados impiden trasladar el principal común del laboratorio.

El primer bloque implementa exclusivamente Validate offline y Plan de lectura, con salida JSON
versionada. El plan offline representa dependencias todavía desconocidas. El plan conectado valida
tenant/suscripción antes de consultar el resto y no considera errores de acceso como ausencia.
Un resultado expresa Validated, Planned, Unverified, Invalid o Blocked y nunca afirma estar listo
para Apply. Los errores no incluyen valores de definiciones rechazadas ni respuestas crudas.

## Consecuencias

El YAML del backend sigue siendo un contrato distinto, sin configuración física de plataformas.
El bootstrap no se elimina con Apocalypse. Apply, reconciliación completa y diagnóstico federado
requieren otro bloque con planes revisados y evidencia de ejecución; no se simulan como disponibles.
La GitHub App de lectura de fuentes conserva su alcance y no se convierte en identidad cloud.

La [guía operativa](../bootstrap-plataformas.md) documenta requisitos, comandos, estados, limitaciones
y pruebas. Los permisos iniciales y consentimientos que requiera el proveedor se solicitan de forma
explícita al ejecutar ese futuro bloque, sin conceder automáticamente autoridad al propio agente.
