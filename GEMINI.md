

# GEMINI.md - K8s GitOps Project Context

## 1. Project Overview

This project is a complete full-stack system running on Kubernetes, deployed using a **GitOps (FluxCD)** model. The system includes everything from infrastructure and secret management to business applications, focusing on automation and Disaster Recovery (DR).

## 2. Tech Stack & Infrastructure

* **Orchestration:** Kubernetes (K8s) using **Kustomize** to manage manifests per environment.
* **GitOps:** **FluxCD** (automated synchronization from Git to the Cluster).
* **Ingress Controller:** **Traefik** (handles routing and SSL termination).
* **Secret Management:** **HashiCorp Vault** (The Single Source of Truth for secrets).
* **Database:** **CloudNativePG (CNPG)** - A powerful PostgreSQL operator for K8s.
* **Internal Git:** **Gitea** (acts as an internal Git server if needed).
* **Applications:**
* Frontend: **Next.js** (React framework).
* Backend: **Python** (FastAPI or Flask).
* Other Components: **Gify** (Integration/Demo application).

```

## 3. Management & Operations Strategy

### 3.1. GitOps & Kustomize Workflow

* All changes must be made via manifest files in the `infrastructure/` directory.
* Use ConfigMaps and Kustomize Patching to alter configurations between environments instead of modifying base files directly.

### 3.2. Secret Management (Vault)

* **NEVER** store secrets directly in Git.
* Use the **External Secrets Operator (ESO)** to pull secrets from Vault into K8s Secrets.
* When generating new manifests, Gemini must specify the correct `SecretStore` or `ExternalSecret` references.

### 3.3. Database & Disaster Recovery (DR)

* **CloudNativePG:** Cluster configuration must include a `backup` section (S3-compatible storage like MinIO or AWS S3).
* **DR Strategy:** Utilize CNPG's `barmanCloud` feature for continuous WAL (Write Ahead Log) archiving and backups.
* In the event of an outage, prioritize recovery using the CNPG `Backup` object.

## 4. Scripting & Demo Data

* **Daily Dump Script:** Written in Python or Bash, running as a `CronJob` in K8s.
* **Task:** Connect to CNPG, perform a `pg_dump`, compress the output, and push it to storage for demo purposes.
* The script must clearly log the execution time and dump file size.

## 5. Coding & Manifest Standards (For Gemini)

1. **Strict Typing:** All Python code must use Type Hints. The Next.js frontend must use TypeScript.
2. **Resource Limits:** Every K8s Deployment must define `resources` (limits/requests).
3. **Labels & Annotations:** Adhere strictly to the `app.kubernetes.io/name` standard for all resources.
4. **Traefik Ingress:** Always use `IngressRoute` (Traefik's CRD) instead of standard Ingresses when advanced features like Middlewares are needed.

## 6. Common Commands (Quick Ops)

* `flux reconcile source git flux-system`: Force an immediate Flux synchronization.
* `kubectl cnpg status [db-name]`: Check the database health.
* `python scripts/db-dump/dump.py`: Run the manual data dump script.

---

### Additional recommendations for your `.gemini/` folder:

1. **`.gemini/prompts/deploy-app.md`**: Contains instructions on how to create a standardized `Deployment` + `Service` + `IngressRoute` for this project so Gemini doesn't use the wrong Traefik formatting.
2. **`.gemini/prompts/dr-test.md`**: Contains a simulated database failure scenario and steps for Gemini to guide you through a CloudNativePG backup recovery.
3. **`.gemini/config.json`**:
```json
{
  "systemInstructionFile": "./GEMINI.md",
  "temperature": 0.1
}

```


*(Keep the temperature low because this is an infrastructure project, requiring extreme precision for YAML syntax).*