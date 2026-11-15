# Cluster GitOps (`cluster-gitops`)

This repository manages declarative Kubernetes manifests, platform services, and Argo CD configurations for homelab
operations and multi-application workloads including [PokeDB](https://github.com/JacobPotter/poke-db).

---

## Repository Structure

```
cluster-gitops/
├── .github/
│   └── workflows/
│       └── promote.yml                      # Production image promotion workflow (apps/poke-db/overlays/prod)
├── apps/                                    # Application workloads
│   ├── open-webui/                          # Open WebUI (Local AI chat interface)
│   │   ├── base/                            # Deployment, Service, PVC, HTTPRoute
│   │   └── overlays/
│   │       └── prod/                        # Production namespace and overlay
│   └── poke-db/                             # PokeDB application
│       ├── base/                            # Base Deployment, Service, ConfigMap, HTTPRoute, Postgres
│       └── overlays/
│           ├── prod/                        # Production pinned image tags (managed by CI)
│           └── preview/                     # Ephemeral PR preview base overlay
├── platform/                                # Cluster-wide platform infrastructure & routing
│   ├── argocd/                              # Declarative Argo CD configurations
│   │   ├── argocd-cm.yaml                   # Core Argo CD settings with external URL
│   │   ├── argocd-cmd-params-cm.yaml        # Server runtime parameters (insecure mode behind Gateway)
│   │   ├── argocd-rbac-cm.yaml              # RBAC policies
│   │   ├── argocd-notifications-cm.yaml     # Notification service, templates, triggers
│   │   ├── argocd-notifications-secret.example.yaml # GitHub App credentials template
│   │   ├── httproute.yaml                   # Argo CD HTTPS & LAN HTTPRoutes
│   │   └── kustomization.yaml
│   ├── gateway/                             # Envoy Gateway & HTTP Redirects
│   │   ├── gateway.yaml                     # Gateway definition (HTTP :80, HTTPS :443 + TLS cert)
│   │   ├── http-redirects.yaml              # Public HTTP-to-HTTPS 301 redirection route
│   │   └── kustomization.yaml
│   ├── minio/                               # MinIO S3 object storage
│   │   ├── deployment.yaml                  # Standalone MinIO deployment (Recreate)
│   │   ├── service.yaml                     # ClusterIP service (S3 API :9000, Console :9001)
│   │   ├── pvc.yaml                         # Persistent storage claim (10Gi RWO)
│   │   ├── secret.yaml                      # Root credentials
│   │   ├── secret.example.yaml              # Root credentials template
│   │   └── kustomization.yaml
│   └── kustomization.yaml                   # Platform root kustomization
├── bootstrap/                               # Argo CD Root Applications
│   ├── open-webui.yaml                      # Application managing Open WebUI (apps/open-webui/overlays/prod)
│   ├── poke-db-prod.yaml                    # Production PokeDB Application
│   ├── poke-db-previews.yaml                # ApplicationSet for PR previews
│   ├── platform.yaml                        # Application managing platform/
│   └── minio.yaml                           # Application managing platform/minio/
└── README.md
```

---

## Storage & Internal Services

### MinIO Object Storage
MinIO provides internal S3-compatible object storage for cluster workloads.

- **S3 API Endpoint**: `http://minio.minio.svc.cluster.local:9000`
- **Web Console Endpoint**: `http://minio.minio.svc.cluster.local:9001`
- **Console Access (Port-Forwarding)**:
  ```bash
  kubectl port-forward -n minio svc/minio 9001:9001
  ```
- **Credentials**: Configured via `minio-secret` in namespace `minio` (`MINIO_ROOT_USER` and `MINIO_ROOT_PASSWORD`).

### Open WebUI (Local AI Interface)
Open WebUI provides a ChatGPT-compatible web interface connected to the host Ollama runtime.

- **Internal Service Endpoint**: `http://open-webui.open-webui.svc.cluster.local:8080`
- **Host Ollama Integration**: Connected to Ollama via downward API (`status.hostIP:11434`).
- **Persistent Storage**: Backed by a 10Gi RWO volume for sqlite metadata, chats, and user settings.
- **Routing**: Strictly internal LAN access via `http://open-webui.pttr-dev-lab`, `http://chat.pttr-dev-lab`, or `http://ai.pttr-dev-lab` (no external exposure).

---

## Traffic & Ingress Routing Flow

- **Public HTTPS Traffic (`*.webwizardssoftware.com`)**: Terminated on Envoy Gateway port 443 with TLS wildcard
  certificates and routed directly to backend services (`frontend:80`, `argocd-server:80`).
- **Public HTTP Redirection**: Port 80 requests for `*.webwizardssoftware.com` are upgraded via Gateway API
  `RequestRedirect` filter to `https://` with HTTP 301.
- **Internal LAN Traffic (`*.pttr-dev-lab`)**: Routes directly on port 80 over HTTP without forced redirection.

---

## Release & Promotion Flow

1. **Production Deployment (`promote.yml`)**:
   - When application code is merged to `main` in `JacobPotter/poke-db`, CI sends a `repository_dispatch` event
     (`promote-prod`) to this repository.
   - The `.github/workflows/promote.yml` workflow updates `apps/poke-db/overlays/prod/kustomization.yaml` with the new
     short SHA tags and commits the change to `main`.
   - Argo CD synchronizes `apps/poke-db/overlays/prod` and rolls out the updated containers into the `poke-db`
     namespace.

2. **Pull Request Preview Environments**:
   - The Argo CD ApplicationSet (`bootstrap/poke-db-previews.yaml`) monitors PRs in `JacobPotter/poke-db` labeled
     `preview`.
   - For each matching PR, an ephemeral environment `poke-db-pr-<N>` is created referencing
     `apps/poke-db/overlays/preview`, deploying PR-specific images (`:pr-<N>`), and exposing
     traffic under `pr-<N>.poke-db.pttr-dev-lab` and `pr-<N>.poke-db.webwizardssoftware.com`.
   - Removing the `preview` label or closing the PR automatically destroys the preview environment.

---

## Local Validation

Render all manifests locally with Kustomize:

```bash
# Applications
kubectl kustomize apps/open-webui/overlays/prod
kubectl kustomize apps/poke-db/overlays/prod
kubectl kustomize apps/poke-db/overlays/preview

# Platform & Ingress
kubectl kustomize platform/argocd
kubectl kustomize platform/gateway
kubectl kustomize platform/minio
kubectl kustomize platform/
```
