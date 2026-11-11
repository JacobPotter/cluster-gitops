---
name: k8s-argocd
description: Guidelines for Kubernetes and ArgoCD GitOps workflows, manifest-based modifications, ApplicationSet previews, and namespace safety in poke-db-gitops. Cross-references k8s-gitops-deployment.
---

# Kubernetes & ArgoCD Local Development Protocol

## Context
- **Infrastructure**: Kubernetes Kustomize manifests in the dedicated GitOps repository [`poke-db-gitops`](https://github.com/JacobPotter/poke-db-gitops) (`base/`, `overlays/`)
- **Deployment Engine**: ArgoCD tracking the `poke-db-gitops` repository (`apps/`)
- **Environment**: Production (`poke-db`) and ephemeral preview (`poke-db-pr-<N>`) namespaces
- **Tooling**: Assume `kubectl` and `argocd` CLIs are installed and configured locally to interact directly with the cluster.
- **Primary Reference**: See `poke-db-gitops` for comprehensive release flow and directory structure.

## Execution Steps

1. Infrastructure Modifications:
   - **NEVER** run `kubectl apply` directly for long-term application resources.
   - All changes to deployments, services, ingress, configmaps, or secrets must be made by modifying manifests in the `poke-db-gitops` repository (`base/` or `overlays/`).

2. ArgoCD Compliance & Sync:
   - When modifying an ArgoCD Application manifest (`apps/argocd-prod.yaml` or `apps/argocd-preview-appset.yaml` in `poke-db-gitops`), ensure target revisions and destination namespaces match cluster expectations.
   - Verify that remote HEAD references and branches in Application specs are reachable and valid.

3. Diagnostics with CLI & Kubernetes MCP:
   - Assume `kubectl` and `argocd` CLIs are configured and available in the environment.
   - Use `kubectl` or Kubernetes MCP (`kubernetes` toolset) with explicit namespace flags (`-n poke-db`, `-n poke-db-pr-<N>`).
   - Use `argocd` CLI to inspect application state, health, and sync status.
   - Check pod logs, rollout status, and PostSync seed hook status (`job/refresh-db-seed`).

4. Namespace & Context Safety:
   - Always append the target namespace explicitly to avoid reading or mutating the wrong cluster context.
   - If a namespace is stuck in `Terminating`, inspect hanging finalizers on custom resources or PVCs before attempting metadata patches.
