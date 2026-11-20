# Bootstrap del estado remoto en Azure

`azure/` crea:

- grupo de recursos dedicado;
- cuenta Storage con autenticación por Microsoft Entra ID, TLS 1.2 y cifrado de infraestructura;
- contenedor privado, versionado y recuperación durante 30 días;
- lock `CanNotDelete` sobre la cuenta;
- keys separadas para bootstrap, `dev`, `staging` y `prod`.

El bootstrap no puede depender inicialmente del backend que crea. El comando Azure genera una copia
controlada con backend local, aplica un plan revisado y transfiere el estado a un backend remoto
separado con `state push` sin force y con locking. Contrasta lineage/serial/recursos y solo entonces
reconfigura el directorio original y elimina las copias locales conocidas. El backend usa
`use_azuread_auth=true`.

La [guía de bootstrap](../../../docs/bootstrap-plataformas.md) documenta la ejecución por etapas,
contenedores y grupos persistentes, identidades federadas en `azure-access/`, verificación y
recuperación.
