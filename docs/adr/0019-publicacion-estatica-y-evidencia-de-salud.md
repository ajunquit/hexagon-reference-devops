# 0019. Publicación estática y evidencia de salud

- Estado: Aceptado; ejecución cloud pendiente
- Fecha: 2026-11-10
- Amplía: [ADR 0018](0018-candidatos-verificados-y-activacion-tras-mantenimiento.md)

## Contexto

El backend ya tiene copia OCI, mantenimiento y activación revisados. Falta publicar el candidato
web en su sitio aislado y comprobar qué está sirviendo. Un comando de publicación con salida 0
no demuestra contenido vigente, configuración pública correcta ni API/Workers saludables.

## Decisión

Application Delivery incorpora PublishWeb y VerifyServing. Descarga de nuevo solo el candidato web
fijado y contrasta su manifiesto y esquema con el commit/hash del release. A una copia del bundle
original añade runtime-config.json, staticwebapp.config.json y un marcador público de despliegue.
La identidad del contenido es determinista y no contiene timestamps ni credenciales.

Se usa el StaticSitesClient oficial de Microsoft mediante el mismo protocolo de entorno utilizado
por SWA CLI. El build y los SHA-256 de Linux/Windows se fijan en Git; no se resuelve latest/stable
en runtime. La instalación se valida sin credenciales y no incorpora Node ni una build de la SPA.
El adaptador no acepta argumentos libres y solo permite variables de publicación conocidas.

La identidad federada obtiene en memoria el token del sitio actual registrado en el inventario.
El proceso recibe únicamente ese token y los parámetros de contenido: omite credenciales de
GitHub/Azure heredadas, no compila app/API y no persiste ni publica su salida libre. La publicación
apunta al slot principal del sitio efímero; no implica elegir el ambiente de producto prod.

PublishWeb guarda Publishing antes de invocar al cliente y Published después de su confirmación.
VerifyServing observa todos los archivos por hash/tamaño, marcador antes/después, MIME, caché y
fallback HTTP de una ruta profunda. Después comprueba imágenes, configuración, identidad, probes,
tráfico, revisión activa y réplicas listas de API/Workers mediante ARM. Guarda evidencia saneada
e inmutable, ligada a inputs y release, antes de marcar la publicación como Verified.

## Consecuencias

La repetición de una publicación incierta entrega exactamente el mismo contenido. También se puede
reconciliar con VerifyServing si el cliente perdió la respuesta pero Azure ya sirve esos bytes.
Una reverificación retira primero el estado Verified anterior; los hechos históricos no equivalen
a disponibilidad permanente. No se deduce retirada ni ausencia de un 403 o de una respuesta parcial.

El journal v1 acepta un campo web opcional; conserva los journals anteriores y la retirada sigue
independiente de él. Se mantienen las protecciones, concurrencia y lease existentes. Terraform
continúa siendo el único propietario de la infraestructura y las aplicaciones no aprovisionan.

Estas comprobaciones no autentican un navegador ni demuestran negocio o reacción de mensajería.
applicationVerified permanece false. El recorrido con Auth/tenant/eventos, limpieza integral
automática y ejecución real de la referencia permanecen pendientes en 9C.
