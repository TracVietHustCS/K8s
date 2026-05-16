# FluxCD + Gitea: Senior DevOps Setup Guide

This guide outlines the production-grade integration of FluxCD with an internal Gitea instance, following the **Multi-Tenancy** and **Separation of Concerns** patterns.

## 🏗️ 1. Recommended Repository Structure

To maintain a clean GitOps workflow, we organize the repository into three logical layers:

```text
.
├── clusters/             # Entry point for Flux (One folder per cluster)
│   ├── production/
│   │   ├── flux-system/  # Auto-generated Flux components
│   │   └── main.yaml     # Main Kustomization pointing to infrastructure
│   └── staging/
├── infrastructure/       # Shared services (Gitea, Vault, CNPG, Traefik)
│   ├── gitea/
│   ├── vault/
│   └── base/
└── apps/                 # Business applications
    ├── python-backend/
    └── nextjs-frontend/
```

---

## 🛠️ Step 1: Deploy Gitea (The Source of Truth)

If Gitea is not yet running, deploy it using the **CloudNativePG** integration for high availability.

1. **Namespace & DB Secret:**
   ```bash
   kubectl create ns gitea
   kubectl create secret generic gitea-db-secret -n gitea --from-literal=password=SuperSecretPass
   ```
2. **Apply Manifests:**
   Use the files in `infrastructure/gitea/base`. Ensure the `IngressRoute` or `Ingress` points to your domain.

---

## 🛠️ Step 2: Configure Gitea for Flux

Before bootstrapping Flux, you need a dedicated repository in Gitea to hold the cluster state.

1. **Create an Organization:** e.g., `gitops-org`.
2. **Create a Private Repo:** e.g., `cluster-config`.
3. **Generate a Personal Access Token (PAT):**
   - Profile -> Settings -> Applications -> Generate Token.
   - Permissions: `repo` (Full access).

---

## 🛠️ Step 3: Bootstrap FluxCD

The `bootstrap` command installs Flux on the cluster and configures it to watch the Gitea repo.

**Command:**
```bash
export GITEA_TOKEN="your-token"
export GITEA_USER="your-username"
export GITEA_URL="https://git.your-domain.com"

flux bootstrap git \
  --url=${GITEA_URL}/${GITEA_USER}/cluster-config.git \
  --allow-http-fallback=false \
  --token-auth=true \
  --password=${GITEA_TOKEN} \
  --branch=main \
  --path=clusters/production
```

> **Senior Tip:** Using `--token-auth` with a PAT is more secure and easier to rotate than SSH keys in some internal environments.

---

## 🛠️ Step 4: Configure the Git Repository Source

Once bootstrapped, tell Flux to track the *current* repository (where your infra and apps live).

**`clusters/production/repository.yaml`**:
```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: main-repo
  namespace: flux-system
spec:
  interval: 1m0s
  url: https://git.your-domain.com/gitops-org/k8s-1.git
  secretRef:
    name: gitea-auth # Created during bootstrap or manually
  ref:
    branch: main
```

---

## 🛠️ Step 5: Define Kustomizations

Create the "bridges" that deploy your code.

**`clusters/production/infrastructure.yaml`**:
```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infrastructure
  namespace: flux-system
spec:
  interval: 10m
  path: ./infrastructure/overlays/prod
  prune: true
  sourceRef:
    kind: GitRepository
    name: main-repo
  wait: true
```

---

## 🔍 Key Considerations for Senior Engineers

1. **Image Updates:** Use `ImageRepository` and `ImagePolicy` CRDs to automate deployments when new Docker images are pushed.
2. **Secret Management:** Flux should NEVER see raw secrets. Use **External Secrets Operator** (pointing to Vault) as defined in your `infrastructure/vault` setup.
3. **Health Checks:** Always set `wait: true` in your Kustomizations to ensure dependencies (like DBs) are ready before apps start.
4. **Pruning:** Always set `prune: true`. If you delete a file in Git, Flux should delete it in the cluster.
