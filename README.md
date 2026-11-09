# PokeDB GitOps (`poke-db-gitops`)

This repository contains the Kubernetes manifests and ArgoCD configuration for [PokeDB](https://github.com/JacobPotter/poke-db).

---

## Repository Structure

```
poke-db-gitops/
├── .github/
│   └── workflows/
│       └── promote.yml               # Automated production promotion via repository_dispatch
├── base/
│   ├── api.yaml                      # API Deployment, Service, ConfigMap, Secret
│   ├── frontend.yaml                 # Frontend Deployment and Service (nginx)
│   ├── httproute.yaml                # Envoy Gateway HTTPRoute
│   ├── postgres.yaml                 # Postgres PVC, Secret, ConfigMap, Deployment, Service
│   ├── refresh-db-cronjob.yaml       # Nightly PokeAPI -> Postgres refresh (CronJob)
│   ├── refresh-db-seed-hook.yaml     # ArgoCD PostSync hook: seeds an empty database
│   └── kustomization.yaml
├── overlays/
│   ├── prod/
│   │   └── kustomization.yaml        # namespace: poke-db, image tags pinned by CI (sha-<short>)
│   └── preview/
│       └── kustomization.yaml        # base overlay for PR previews
└── apps/
    ├── argocd-notifications-cm.yaml           # Notification service, templates, triggers
    ├── argocd-notifications-secret.example.yaml # Example secret template for GitHub App credentials
    ├── argocd-prod.yaml                       # ArgoCD Application for poke-db (production)
    └── argocd-preview-appset.yaml             # ApplicationSet: one preview env per PR labelled "preview" in poke-db
```

---

## Release & Promotion Flow

1. **Production Deployment (`promote.yml`)**:
   - When application code is merged to `main` in `JacobPotter/poke-db`, its CI pipeline publishes `:sha-<short>` images to GHCR and sends a `repository_dispatch` event (`promote-prod`) to this repository.
   - The `.github/workflows/promote.yml` workflow updates `overlays/prod/kustomization.yaml` with the new image tags and commits the change to `main`.
   - The ArgoCD Application (`apps/argocd-prod.yaml`) syncs the updated overlay and rolls out the new container images into the `poke-db` namespace.

2. **Pull Request Preview Environments**:
   - The ArgoCD ApplicationSet (`apps/argocd-preview-appset.yaml`) monitors PRs in `JacobPotter/poke-db` labeled `preview`.
   - For each matching PR, an ephemeral environment `poke-db-pr-<N>` is spun up referencing `overlays/preview` and pointing to `ghcr.io/jacobpotter/poke-db-{api,frontend}:pr-<N>`.
   - When the PR is closed or the `preview` label is removed, ArgoCD automatically cleans up the Application.

---

## Manual Validation

To render manifests locally:

```bash
kubectl kustomize overlays/prod
kubectl kustomize overlays/preview
```
