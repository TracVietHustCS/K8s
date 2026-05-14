# Vault Homelab Setup & Routing Guide

This document explains the lightweight, path-based Vault setup on your K8s cluster.

## 🏗️ 1. Architecture: Lightweight Standalone
- **Mode:** Standalone (1 Replica) to save RAM/CPU.
- **Storage:** `file` backend using `local-path` storage (4GB).
- **Security:** Manual Shamir Unseal (3/5 keys).

## 🚀 2. Traffic Flow (Trace-routing Demo)

When you access `http://123.16.178.213:2001/vault`, here is what happens:

1.  **Browser → Router:** Request hits your Public IP/NAT on port `2001`.
2.  **Router → K8s Node:** Router forwards port `2001` to your Worker Node port `80` (Traefik `hostPort`).
3.  **Traefik Entrypoint:** Traefik receives the request at path `/vault`.
4.  **Middleware (StripPrefix):** 
    - Traefik sees the `vault-strip-prefix` middleware.
    - It transforms the request from `/vault` to `/`.
5.  **Vault Service:** Traefik routes the cleaned request (`/`) to the `vault` service on port `8200`.
6.  **Vault Pod:** Vault receives the request. Since it's a browser, it responds with a **307 Redirect** to `/ui/`.
7.  **Loopback:** Your browser sees the redirect and requests `/ui/`. Traefik matches the `PathPrefix('/ui')` rule and sends it back to Vault.
8.  **Success:** The Vault UI loads in your browser.

## 🔑 3. Critical Management Commands

### Check Status
```bash
kubectl exec -it vault-0 -n vault -- vault status
```

### Unseal (After every Node/Pod restart)
```bash
kubectl exec -it vault-0 -n vault -- vault operator unseal <KEY_1>
kubectl exec -it vault-0 -n vault -- vault operator unseal <KEY_2>
kubectl exec -it vault-0 -n vault -- vault operator unseal <KEY_3>
```

### Login via CLI
```bash
kubectl exec -it vault-0 -n vault -- vault login <ROOT_TOKEN>
```

---

## 💡 Troubleshooting
- **404 Page Not Found:** Usually means Traefik hasn't picked up the `IngressRoute` or the `Middleware` prefix is wrong.
- **503 Service Unavailable:** Vault is likely **Sealed**. Check status and unseal.
