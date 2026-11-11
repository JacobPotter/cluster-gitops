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
│   └── kustomization.yaml                   # Platform root kustomization
├── bootstrap/                               # Argo CD Root Applications
│   ├── poke-db-prod.yaml                    # Production PokeDB Application
│   ├── poke-db-previews.yaml                # ApplicationSet for PR previews
│   └── platform.yaml                        # Application managing platform/
└── README.md
```

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
     `apps/poke-db/overlays/preview`, deploying commit-specific images (`:sha-{{.head_short_sha}}`), and exposing
     traffic under `pr-<N>.poke-db.pttr-dev-lab` and `pr-<N>.poke-db.webwizardssoftware.com`.
   - Removing the `preview` label or closing the PR automatically destroys the preview environment.

---

## Local Validation

Render all manifests locally with Kustomize:

```bash
# Applications
kubectl kustomize apps/poke-db/overlays/prod
kubectl kustomize apps/poke-db/overlays/preview

# Platform & Ingress
kubectl kustomize platform/argocd
kubectl kustomize platform/gateway
kubectl kustomize platform/
```
