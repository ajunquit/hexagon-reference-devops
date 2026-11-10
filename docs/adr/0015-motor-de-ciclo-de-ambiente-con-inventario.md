# ADR 0015: motor del ciclo de ambiente con inventario

- Estado: aceptada; motor y pruebas implementados, adaptador cloud y workflows pendientes
- Fecha: 2026-11-09
- Amplía: [ADR 0012](0012-genesis-y-apocalypse-por-ambiente.md)

## Contexto

Genesis y Apocalypse necesitan compartir selección, orden y recuperación. La destrucción debe
seguir funcionando sin los artefactos de aplicaciones o el CI que originalmente los produjo.
La ruta de 9C ordena implementar primero inventario, planes, fallo parcial y verificación, y
después conectar las entradas manuales y ejecutar el recorrido efímero.

## Decisión

EnvironmentInventory v1 fija producto, ambiente, instancia, identidad, backend, fuentes y hashes,
roots con dependencias, estados y recursos observados. Una instancia efímera usa run-ID-attempt y
nunca las claves persistentes. Los roots conocidos son AzureHosting y AzureServiceBus para la
primera composición; no hay rutas Terraform ni comandos libres en el contrato.

El motor ordena el alta por dependencias y la baja en orden inverso. Aplica una etapa solo con
planes revisados y vigentes, hashes coincidentes, revisión actual del inventario y preflight.
Rechaza reemplazos/destrucciones durante Create, importaciones y borrados de recursos no registrados.
No administra grupos, federación ni locks del bootstrap. El estado preserva los IDs históricos.

Antes de ejecutar exige un checkpoint duradero del intento, con hash, revisión, destino y snapshot
confirmados. Un fallo conserva el inventario y bloquea dependientes. Un intento interrumpido debe
reconciliarse mediante observación, sin repetir automáticamente un plan anterior. La baja exige
estado leído, ámbito accesible y completo, ausencia de recursos restantes y sondas de todos los IDs.
Denied, Unknown, respuestas parciales o lineage distinto no acreditan ausencia. Producción requiere
política BackupRequired y evidencia de respaldo y quiescencia ligada a la instancia/root.

Persistencia remota, Terraform y observación del proveedor se conectan mediante un puerto de código
obligatorio, sin implementación por defecto. Este bloque implementa el motor, la persistencia local
atómica y el protocolo; los tests usan un doble explícito. No incorpora todavía el adaptador Azure
ni las entradas Genesis/Apocalypse. Una respuesta simulada no acredita un bootstrap o ambiente real.

## Consecuencias

La orquestación futura reutilizará este motor, con un adaptador que valide identidad y artefactos,
almacene el inventario y snapshots de forma duradera, controle concurrencia distribuida y lea el
proveedor. Antes de conectarlo a Azure se requiere el bootstrap aislado del PR #15 y la identidad
propia de la instancia efímera; la identidad persistente de dev no prueba ese aislamiento.

La verificación del motor acredita infraestructura según observaciones del adaptador confiable,
no la SPA, migraciones, API, Workers ni el recorrido navegador → API. applicationVerified permanece
false. El JSON no es una credencial ni evidencia independiente: debe custodiarse y recuperarse desde
un almacenamiento confiable. La fase 9C permanece abierta hasta el recorrido cloud integral.
