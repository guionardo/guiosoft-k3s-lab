# GitOps, secrets e infraestructura reproducible

Después de añadir aplicaciones y observabilidad a mi clúster K3s, una pregunta empezó a incomodarme: **¿cuánto de este entorno existe porque está declarado y cuánto existe solamente porque recuerdo los comandos que ejecuté?**

La siguiente etapa consistió en reducir las decisiones que existían únicamente en el estado actual de la máquina.

## Tres capas, tres responsabilidades

```mermaid
flowchart LR
    A[Ansible] --> H[Estado del host Debian y K3s]
    T[Terraform] --> E[Recursos externos]
    F[Flux / Kubernetes / Helm] --> C[Estado interno del clúster]
```

Las herramientas pueden solaparse en capacidad sin solaparse en ownership. Para mí, una infraestructura reproducible empieza cuando está claro **quién es responsable de cada estado**.

## ¿Por qué Flux?

Elegí Flux porque el repositorio ya contenía manifests Kubernetes y Helm, y ya había adoptado SOPS + age para secrets. La decriptación SOPS nativa de `kustomize-controller` y el modelo pull-based encajaban bien con el laboratorio.

## Empezar por el workload menos peligroso

El primer workload bajo ownership de Flux fue `cloudflared`: pequeño, stateless, declarativo y con rollback sencillo.

```mermaid
flowchart TD
    N[Namespace] --> S[Secret cifrado con SOPS]
    S --> C[cloudflared]
```

Después validé drift manual, cambio versionado, rollback por Git y eliminación deliberada de un Secret seguida de su reconstrucción desde el repositorio cifrado. GitOps sin una prueba de reconstrucción puede ser solamente sincronización optimista.

## Secrets en Git, pero no en plaintext

```mermaid
flowchart LR
    Git[Git: Secret cifrado con SOPS] --> Flux[Flux]
    Age[Identidad age en runtime] --> Flux
    Flux --> Secret[Secret Kubernetes]
    Secret --> W[Workload]
```

El recipient público puede estar en el repositorio; la identidad privada no. Esto produce una consecuencia importante para DR: **Git por sí solo no reconstruye el clúster.** La identidad privada necesita una ruta independiente de recuperación.

## Self-healing necesita ser observado

Después de `cloudflared`, Firecrawl pasó a Flux. Introduje drift positivo escalando manualmente la API de una a dos réplicas.

```mermaid
flowchart LR
    G[Git declara 1 réplica] --> F[Reconciliación Flux]
    D[Clúster manual: 2 réplicas] --> F
    F --> R[Clúster vuelve a 1 réplica]
```

El endpoint siguió disponible mientras Flux restauraba el estado declarado.

## Adoptar recursos existentes sin recrearlos

Prometheus, Grafana, Loki, Tempo, Alloy y OpenTelemetry Collector ya existían antes de Flux. Los HelmReleases se declararon para coincidir con los releases existentes, inicialmente suspendidos, y se activaron en orden conservador:

```mermaid
flowchart LR
    A[Alloy] --> O[OpenTelemetry Collector]
    O --> T[Tempo]
    T --> L[Loki]
    L --> K[kube-prometheus-stack]
```

En cada etapa validé HelmRelease Ready, releases runtime, Pods, PVCs y los flujos funcionales de métricas, logs y traces. La adopción de GitOps fue una migración de ownership, no un redeploy ciego.

## GitOps no sustituye rollback

Si una reconciliación causa un problema, puedo suspender solamente la Kustomization o HelmRelease afectada, corregir Git y reanudar la reconciliación. La automatización es útil cuando también existe un camino claro para interrumpirla.

## Idempotencia como evidencia

Al reorganizar Ansible para separar variables comunes, producción y DR, el dry-run de producción terminó con:

```text
ok=16
changed=0
failed=0
```

Mientras tanto, el inventario DR deja backup consistente, R2 y `cloudflared` en `false` por defecto. No es solamente organización de YAML; reduce el blast radius.

## ¿Qué puede reconstruir Git?

```mermaid
flowchart LR
    Git[Git] --> Flux[Flux] --> K8s[Kubernetes]
    Enc[Git cifrado] --> SOPS[SOPS / age] --> Secrets[Secrets]
    Ansible[Ansible] --> Host[Host / K3s]
    Terraform[Terraform] --> External[Recursos externos]
```

Pero seguía faltando responder la pregunta principal: **si el servidor desaparece, ¿puedo realmente restaurarlo todo en otra máquina?**

Tener backups y poder hacer Disaster Recovery son cosas diferentes. Lo aprendí ejecutando el restore de verdad.

---

Proyecto: `guionardo/guiosoft-k3s-lab`.
