# Gitea Deployment Plan (Best Practice)

This plan outlines how to deploy Gitea in your homelab, leveraging the **CloudNativePG** cluster for the database and your **Traefik** ingress for external access.

## 🏗️ Architecture Overview

- **App:** Gitea (Official Helm Chart)
- **Database:** CloudNativePG PostgreSQL Cluster (`gitea-db`)
- **Ingress:** Traefik (using ports 2001/2002 for Web traffic)
- **SSH:** Git-over-SSH via a dedicated NAT port (e.g., 2022)
- **Storage:** Persistent Volumes for repositories and configuration

---

## 🛠️ Step 1: Prepare Database Credentials
CNPG automatically creates a superuser secret, but for Gitea, we should create a dedicated user and database using a `Postgresql` resource or manual SQL.

1. **Create the Gitea User Secret:**
```bash
kubectl create secret generic gitea-db-secret \
  --from-literal=password=YourSecurePassword \
  --namespace gitea
```

2. **Wait for CNPG to be ready:** Ensure your Postgres cluster is running before proceeding.

---

## 🛠️ Step 2: Configure Gitea Helm Values
Create a `gitea-values.yaml` file. This configuration uses your specific NAT/Traefik setup.

```yaml
gitea:
  config:
    database:
      DB_TYPE: postgres
      HOST: gitea-db-rw.gitea.svc.cluster.local:5432
      NAME: gitea
      USER: gitea
      # PASSWD is handled via secret reference below
    server:
      DOMAIN: your-domain.com # Change to your DDNS or IP
      HTTP_PORT: 3000
      SSH_DOMAIN: your-domain.com
      SSH_PORT: 2022 # Matching your NAT forwarding
      SSH_LISTEN_PORT: 22

  database:
    builtIn:
      enabled: false # Use CloudNativePG instead

# Link to the CNPG Secret
extraSecrets:
  - name: gitea-db-secret

ingress:
  enabled: true
  className: traefik
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
  hosts:
    - host: git.your-domain.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - hosts:
        - git.your-domain.com

# SSH Service (using NodePort to match your NAT range)
sshService:
  type: NodePort
  port: 22
  nodePort: 2022 # This must be in your 2001-2200 range
```

---

## 🛠️ Step 3: Deployment
Deploy Gitea using Helm:

```bash
helm repo add gitea-charts https://dl.gitea.com/charts/
helm repo update

helm upgrade --install gitea gitea-charts/gitea \
  --namespace gitea \
  --values gitea-values.yaml
```

---

## 🔍 Why this is "Best Practice"

1. **Database Decoupling:** By using CNPG, you can scale or backup your database independently of Gitea.
2. **Security:** Credentials are managed via K8s Secrets, not hardcoded.
3. **High Availability:** CNPG provides a multi-node database. If one worker node fails, the DB stays up.
4. **Git over SSH:** Using a `NodePort` in your allowed NAT range (2001-2200) ensures you can perform `git push` from anywhere.
5. **Traefik Integration:** Leveraging your existing Traefik setup for TLS termination and path-based routing.

---

## 💡 Knowledge Check: Why NodePort for SSH?
Since your router forwards ports 2001-2200 directly to your worker nodes, a **NodePort** service is the most direct way to bridge external traffic to the Gitea SSH service without a complex LoadBalancer (which usually requires a Cloud provider).
