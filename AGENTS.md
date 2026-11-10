# hexagon-template-devops — instrucciones para agentes de IA

Este repositorio es la plantilla de infraestructura, despliegue y operación de un producto
Hexagon. Cada producto genera una instancia independiente, por ejemplo `hexagon-hr-devops`.

## Reglas

1. La plantilla solo contiene mecanismos reutilizables. No lleva nombres, cuentas, suscripciones,
   dominios, secretos ni reglas de un producto real.
2. Un repositorio generado administra un solo producto. Todos los productos empiezan con backend
   de monolito modular y conservan el mismo repositorio DevOps si más adelante extraen servicios.
   No existen variantes `hexagon-template-devops-ml` o `hexagon-template-devops-ms`. La
   infraestructura compartida entre productos pertenece a un repositorio de plataforma separado.
3. Las aplicaciones declaran necesidades lógicas mediante manifiestos versionados bajo
   `.hexagon/`. DevOps consume un commit completo y verifica el `SHA-256`; nunca modifica esos
   manifiestos ni infiere requisitos desde el código.
4. Todo recurso físico, topología, identidad, política y binding de despliegue se define aquí. La
   API, los Workers y el frontend no crean infraestructura en runtime.
5. Terraform es la única herramienta de IaC; esta decisión no es intercambiable por OpenTofu,
   Pulumi u otra herramienta. El estado es remoto, separado por producto y ambiente, y nunca se
   confirma en Git. Su bootstrap queda fuera del estado que crea.
6. Los módulos de Azure, AWS y RabbitMQ permanecen separados. No se crea una abstracción común que
   oculte capacidades o semánticas distintas de los proveedores.
7. Los secretos se guardan en el gestor del proveedor o se entregan por identidad. Nunca aparecen
   en descriptores, variables versionadas, planes, ejemplos, logs o descripciones de PR.
8. `dev`, `staging` y `prod` tienen estados y políticas independientes. Una promoción cambia el
   descriptor a otro commit inmutable; no recompila la aplicación ni toma una rama mutable.
9. Código, scripts, variables y comentarios en inglés. README, CHANGELOG, `docs/` y ADR en español.
10. Los scripts son deterministas, idempotentes cuando realizan cambios y admiten `-WhatIf` cuando
    escriben. Deben validar precondiciones antes de modificar recursos externos.
11. No se añaden workflows, despliegues ni recursos cloud antes de su fase autorizada. La fase 3
    solo cubre estructura, contratos, validación y elección de herramienta.
12. Una rama por cambio desde `main`; commits y PR en español. Todo cambio funcional actualiza
    `CHANGELOG.md` y su documentación.
13. Operación según `docs/operacion-mensajeria.md`: política por consumidor, identidad distinta de
    los workloads, inspección pasiva y reproducción acotada desde DLQ. Conserva `HexagonMessageId`,
    tenant y cuerpo; retira el original solo después de publicar. No escribas cuerpos ni excepciones
    libres en logs. `Replay` sin `-Execute` solo genera un plan. Nunca borres filas del inbox para
    forzar una recuperación.
14. Preparación de plataformas según `docs/bootstrap-plataformas.md`: usa la definición YAML y
    `scripts/Invoke-PlatformBootstrap.ps1`. Validate/Plan son de lectura; Prepare crea el plan local;
    Apply exige el hash revisado, por etapa; Migrate conserva el estado hasta contrastar el remoto.
    Verify solo acredita la plataforma con el diagnóstico real en success. No confundas Prepared,
    Applied o exit code 0 con Verified. Bootstrap conserva grupos e identidades; los workloads
    consultan esos grupos y nunca los vuelven a administrar. No ejecutes cloud con el YAML ficticio.

15. Motor de ambiente según `docs/motor-ciclo-ambiente.md`: usa EnvironmentInventory v1 y el grafo
    de roots; nunca deduzcas ausencia de errores de acceso ni borres el inventario tras un fallo.
    Instancias efímeras y persistentes tienen IDs/keys distintos. El puerto de código es obligatorio;
    su doble de pruebas no es un adaptador cloud. El adaptador Terraform/Azure y su custodia Blob
    siguen `docs/adaptador-ciclo-azure.md`; usa su CLI, snapshots confiables y lease/CAS. No rompas
    leases automáticamente ni reutilices planes después de cambiar inputs. Reservas y workflows
    efímeros siguen `docs/ciclo-efimero-azure.md`: bootstrap del operador separado, contenedor por
    instancia, Prepare/Apply en despachos distintos y quiescencia explícita. Nunca concedas esos
    permisos de bootstrap a los workflows de workloads. BackupRequired se bloquea sin verificador real de respaldos.
    No trates un JSON con status Verified ni applicationVerified=false como evidencia de producto operativo.
16. Entrega según `docs/entrega-aplicaciones-azure.md`: candidatos por ID y hash de CI main success,
    copia OCI sin reconstruir y mantenimiento antes de activar. Conserva el journal y el marcador
    del intento antes de arrancar jobs; nunca repitas POST ante una respuesta ambigua. Compartir
    Environment, concurrencia y lease con Genesis/Apocalypse es obligatorio.
17. Publicación y salud según `docs/publicacion-spa-y-salud.md`: conserva el bundle de CI, usa el
    cliente Microsoft fijado por checksum y entrega el token solo al proceso. Published no acredita
    contenido servido: VerifyServing compara archivos, caché/fallback y revisiones/réplicas actuales.
    No uses esa evidencia como E2E autenticado ni como disponibilidad permanente.
18. Aceptación según `docs/aceptacion-integral-azure.md` y ADR 0020: PrepareAcceptance y Acceptance
    son despachos separados. La retirada automática solo admite el conjunto exacto de recursos
    efímeros dev/staging consentido por hash; cada plan delete-only pasa por el motor y conserva
    evidencia antes de borrar. No amplíes esa excepción a Genesis/Apocalypse o datos persistentes.
    No guardes tokens ni sesiones del navegador. Una interrupción requiere recuperación revisada.

## Comprobaciones antes de un PR

La suite necesita las dependencias de `acceptance/package-lock.json` y su Chromium: ejecuta
`npm ci --prefix acceptance --ignore-scripts` y
`node acceptance/node_modules/playwright/cli.js install chromium` la primera vez (en Linux,
`install --with-deps chromium` si faltan bibliotecas del sistema).

```powershell
pwsh ./scripts/Test-Repository.ps1
```

Si cambia un descriptor real, también se ejecuta:

```powershell
pwsh ./scripts/Test-ProductEnvironmentDescriptor.ps1 `
  -Descriptor <ruta-al-descriptor> `
  -VerifySources
```

No se ejecuta `terraform apply` de workloads desde una estación local contra ambientes compartidos.
El operador ejecuta el bootstrap persistente con el comando documentado y planes revisados; el
agente no lo aplica a una cuenta real sin un destino concreto autorizado. El diagnóstico manual
requiere main y las protecciones de cada Environment. Genesis/Apocalypse admiten por ahora solo
instancias efímeras dev/staging y no acreditan aplicaciones operativas ni cierre de 9C.
