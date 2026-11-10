# Productos

Cada instancia generada de la plantilla administra un único producto y escribe aquí un descriptor
por ambiente:

```text
products/
└── hexagon-hr/
    └── environments/
        ├── dev/
        │   ├── descriptor.json
        │   └── <provider>-policy.json
        ├── staging/
        │   ├── descriptor.json
        │   └── <provider>-policy.json
        └── prod/
            ├── descriptor.json
            └── <provider>-policy.json
```

Los archivos se generan con `scripts/New-ProductEnvironmentDescriptor.ps1`. No copies el ejemplo a
mano: el script resuelve commits, valida los manifiestos y calcula sus resúmenes.

DevOps añade una sola política que coincide con el proveedor del backend:

- `azure-service-bus-policy.json` para Azure;
- `aws-sns-sqs-policy.json` para AWS;
- `rabbitmq-policy.json` para RabbitMQ.

La política contiene decisiones físicas e identidades no secretas; no duplica routing ni
workloads. El validador exige correspondencia exacta con el manifiesto backend.

No se versionan en esta carpeta bindings, credenciales, planes ni estado de Terraform.
