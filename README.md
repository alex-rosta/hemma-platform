# hemma-platform

GitOps homelab on single node k3s, managed by ArgoCD.

## Prerequisites

- k3s with default Traefik disabled (`--disable traefik`)
- `kubectl` and `helm` installed
- Cloudflare account with domain and API token for DNS-01 challenge
- Persistent data directories:
  ```bash
  sudo mkdir -p /mnt/data/openbao /mnt/data/keycloak-postgresql
  ```

## Bootstrap

```bash
REPO_URL=https://github.com/alex-rosta/hemma-platform.git ./bootstrap/install.sh
```

Then port-forward ArgoCD and grab the password:

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

## Post-Bootstrap

### 1. Bootstrap the Cloudflare API token (for cert-manager DNS-01)

This secret must exist before cert-manager can issue certs. ArgoCD will create the namespace on sync, but if it hasn't yet:

```bash
kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
kubectl -n cert-manager create secret generic cloudflare-api-token \
  --from-literal=api-token=<CF_API_TOKEN>
```

### 2. Initialize and unseal OpenBao

```bash
kubectl -n openbao wait --for=condition=Ready pod/openbao-0 --timeout=300s
kubectl exec -n openbao openbao-0 -- bao operator init -key-shares=1 -key-threshold=1
kubectl exec -n openbao openbao-0 -- bao operator unseal <UNSEAL_KEY>
kubectl exec -n openbao openbao-0 -- bao secrets enable -path=secret kv-v2
```

Save the unseal key and root token — you need the unseal key after every pod restart.

### 3. Seed secrets in OpenBao

```bash
kubectl port-forward svc/openbao -n openbao 8200 &
export BAO_ADDR=http://127.0.0.1:8200
export BAO_TOKEN=<ROOT_TOKEN>

bao kv put secret/hemma/cloudflare api-token=<CF_API_TOKEN>
bao kv put secret/hemma/cloudflared-tunnel tunnel-token=<TOKEN_FROM_CLOUDFLARE_DASHBOARD>
bao kv put secret/hemma/grafana user=admin password=<PASSWORD>
bao kv put secret/hemma/keycloak password=<PASSWORD>
bao kv put secret/hemma/keycloak-postgresql password=<PASSWORD> postgres-password=<PASSWORD>
```

### 4. Connect ESO to OpenBao

Same bootstrap problem — ESO needs a token to talk to OpenBao, but ESO itself is deployed by ArgoCD.

```bash
kubectl create namespace external-secrets --dry-run=client -o yaml | kubectl apply -f -
kubectl -n external-secrets create secret generic openbao-token \
  --from-literal=token=<BAO_TOKEN>
```

These are the only two manual secrets. After this, everything syncs automatically via ExternalSecrets.

### 5. Configure Cloudflare Tunnel

Create a tunnel in the [Cloudflare dashboard](https://one.dash.cloudflare.com/) and configure your public hostnames to point to `https://traefik.traefik:443` with TLS verification disabled.

## Adding Apps

**Helm chart** — add an entry to `apps/helm-apps.yaml` and create `platform/<name>/values.yaml`.

**Plain manifests** — add an entry to `apps/manifest-apps.yaml` and create `platform/<name>/` with your YAML files.

## Reset

To wipe the cluster and start fresh:

```bash
/usr/local/bin/k3s-uninstall.sh
sudo rm -rf /mnt/data/openbao /mnt/data/keycloak-postgresql
sudo mkdir -p /mnt/data/openbao /mnt/data/keycloak-postgresql
```

Then reinstall k3s (`--disable traefik`) and re-run the bootstrap.

## Structure

```
apps/                     # ApplicationSets (generates ArgoCD Applications)
├── helm-apps.yaml        # Upstream Helm charts
└── manifest-apps.yaml    # Plain manifest directories
platform/                 # Per-service config and values
bootstrap/install.sh      # One-time cluster bootstrap
```
