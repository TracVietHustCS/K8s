  # Gitea to Vault Migration Plan (Using External Secrets Operator)

## Overview
This plan outlines the steps to remove plain-text secrets from Git (`secrets.yaml`) and replace them with `ExternalSecret` definitions that pull credentials directly from HashiCorp Vault. This aligns with the Zero-Trust and "No secrets in plain text" policies defined in `DEVOPS.md`.

## Prerequisites
1. Vault is running and unsealed.
2. The secrets `secret/gitea/db` and `secret/gitea/admin` have been created in Vault (as done in the previous step).
3. **External Secrets Operator (ESO)** must be installed on your Kubernetes cluster.

---

## Step 1: Create a SecretStore for Vault
ESO needs to know how to connect to Vault and how to authenticate. We define this using a `SecretStore`.

Create a new file `apps/base/gitea/secret-store.yaml`:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: vault-backend
spec:
  provider:
    vault:
      server: "http://vault.vault.svc.cluster.local:8200" # Internal DNS for Vault Service
      path: "secret"
      version: "v2"
      auth:
        # For homelab/demo: We use a static token. 
        # (In Production, you would use Kubernetes Service Account JWT auth)
        tokenSecretRef:
          name: vault-token-secret
          key: token
```

**Action Required on Cluster:** You need to manually create the `vault-token-secret` once directly on the cluster so ESO can log into Vault. Run this in your terminal:
```bash
# Replace YOUR_ROOT_TOKEN with your actual Vault token
kubectl create secret generic vault-token-secret --from-literal=token="YOUR_ROOT_TOKEN"
```

---

## Step 2: Replace Plaintext Secrets with ExternalSecrets
1. **Delete the unsafe plaintext file:**
   Delete `apps/base/gitea/secrets.yaml` so it is no longer tracked in Git.

2. **Create the ExternalSecret definitions:**
   Create a new file `apps/base/gitea/external-secrets.yaml`:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: gitea-db-ext-secret
spec:
  refreshInterval: "1h"
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    name: gitea-db-secret # This must exactly match what database.yaml and deployment.yaml expect
    template:
      type: kubernetes.io/basic-auth
  data:
    - secretKey: username
      remoteRef:
        key: gitea/db
        property: username
    - secretKey: password
      remoteRef:
        key: gitea/db
        property: password
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: gitea-admin-ext-secret
spec:
  refreshInterval: "1h"
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    name: gitea-admin-secret
    template:
      type: Opaque
  data:
    - secretKey: admin-password
      remoteRef:
        key: gitea/admin
        property: admin-password
```
*How it works: ESO will read these files, connect to Vault, grab the values, and automatically generate the standard Kubernetes `Secret` objects (`gitea-db-secret` and `gitea-admin-secret`).*

---

## Step 3: Update Kustomization
We need to tell Kustomize to stop using the old `secrets.yaml` and use our two new files instead.

Update `apps/base/gitea/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - secret-store.yaml      # <-- Added
  - external-secrets.yaml  # <-- Added
  - database.yaml
  - pvc.yaml
  - deployment.yaml
  - service.yaml
  - ingress.yaml
# Removed: - secrets.yaml
```

---

## Step 4: Deploy Gitea to the Cluster
Now that the configuration is safe and uses Vault, deploy it using the Production overlay we created earlier.

Run the following command:
```bash
kubectl apply -k apps/overlays/prod/gitea
```

---

## Step 5: Verification & Troubleshooting
Verify that the complete chain is working:

1. **Check if ESO successfully fetched the secrets from Vault:**
   ```bash
   kubectl get externalsecrets
   ```
   *Look for `True` under the `READY` column. If it's `False`, check the SecretStore authentication.*

2. **Check if the actual Kubernetes Secrets were generated:**
   ```bash
   kubectl get secret gitea-db-secret gitea-admin-secret
   ```

3. **Check if Gitea and Database are running successfully:**
   ```bash
   kubectl get pods -l app.kubernetes.io/name=gitea
   kubectl cnpg status gitea-db
   ```
