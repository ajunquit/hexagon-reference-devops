# Reserva de una instancia efímera Azure

Root de bootstrap del operador, separado de los estados de workloads. Crea grupos protegidos,
identidad por instancia, federación al Environment exacto, contenedor privado y RBAC acotado.
No recibe permisos de este root la identidad persistente de dev ni una aplicación.

Usa `scripts/Invoke-EphemeralBootstrap.ps1` desde la raíz DevOps, con un plan revisado. El backend
es el Storage preexistente del bootstrap. No ejecutes apply con ejemplos ni retires prevent_destroy.
Apocalypse conserva estos recursos y la evidencia. La
[guía del ciclo](../../../docs/ciclo-efimero-azure.md) explica preparación, GitHub y recuperación.
