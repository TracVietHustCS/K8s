# Gitea to Vault Migration Plan (Using External Secrets Operator)

## Overview
This plan outlines the steps to remove plain-text secrets from Git (`secrets.yaml`) and replace them with `ExternalSecret` definitions that pull credentials directly from HashiCorp Vault. This aligns with the Zero-Trust and "No secrets in plain text" policies defined in `DEVOPS.md`.

## Prerequisites
1. Vault is running and unsealed.
2. The secrets `secret/gitea/db` and `secret/gitea/admin` have been created in Vault.
3. **External Secrets Operator (ESO)** must be installed on your Kubernetes cluster.

---

## Step 1: Create a SecretStore for Vault
ESO needs to know how to connect to Vault and how to authenticate. We define this using a `SecretStore`.

```yaml
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: vault-backend
  namespace: gitea
spec:
  provider:
    vault:
      server: "http://vault.vault.svc.cluster.local:8200"
      path: "secret"
      version: "v2"
      auth:
        tokenSecretRef:
          name: vault-token-secret
          key: token
```

---

## Step 2: Replace Plaintext Secrets with ExternalSecrets
I have replaced `secrets.yaml` with `ExternalSecret` definitions.

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: gitea-db-ext-secret
  namespace: gitea
spec:
  refreshInterval: "1h"
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    name: gitea-db-secret
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
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: gitea-admin-ext-secret
  namespace: gitea
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

---

## Step 3: Execution Log & Verification (Auto-Generated)

### Deployment Summary (2026-05-15)
- **Infrastructure:**
  - Installed **External Secrets Operator (ESO)** via Helm.
  - Installed **CloudNativePG (CNPG)** Operator via Helm.
- **Vault Configuration:**
  - Repaired `secret/gitea/db` and `secret/gitea/admin` keys in Vault KV-v2.
  - Created `vault-token-secret` in `gitea` namespace for ESO authentication.
- **Application Deployment:**
  - Created `gitea` namespace.
  - Deployed **CNPG Cluster** (`gitea-db`) with 2 instances.
  - Deployed **Gitea** using dynamic secrets from Vault.
  - Configured **Traefik IngressRoute** for path-based access (`/gitea`).

### Verification Results
```bash
$ kubectl get externalsecrets -n gitea
NAME                     STORE           READY   STATUS
gitea-admin-ext-secret   vault-backend   True    SecretSynced
gitea-db-ext-secret      vault-backend   True    SecretSynced

$ kubectl get pods -n gitea
NAME                    READY   STATUS    RESTARTS
gitea-5b5568667-b9bmg   1/1     Running   0
gitea-db-1              1/1     Running   0
gitea-db-2              1/1     Running   0
```

### Access Information
- **URL:** `http://123.16.178.213:2001/gitea/`
- **Secrets:** Dynamically pulled from Vault via ESO.

**Status:** ✅ **Production Ready.**
