#!/usr/bin/env bash
set -euo pipefail

# Bootstrap hemma-platform
# Assumes k3s is already running (with default Traefik disabled) and
# kubectl is configured to talk to the cluster.
#
# Prerequisites:
#   - k3s running with: --disable traefik
#   - helm and kubectl installed on this machine
#   - kubeconfig pointing at the cluster

REPO_URL="${REPO_URL:-https://github.com/alex-rosta/hemma-platform.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"

echo "==> hemma-platform bootstrap"
echo "    Repo:   ${REPO_URL}"
echo "    Branch: ${REPO_BRANCH}"
echo ""

# --- 0. Prerequisites ---
for tool in helm kubectl; do
  if ! command -v "$tool" &>/dev/null; then
    echo "ERROR: ${tool} is required but not found in PATH."
    exit 1
  fi
done

echo "==> Verifying cluster connectivity..."
if ! kubectl cluster-info &>/dev/null; then
  echo "ERROR: Cannot connect to Kubernetes cluster. Check your kubeconfig."
  exit 1
fi
kubectl get nodes

# --- 1. Install ArgoCD via Helm ---
echo "==> Installing ArgoCD (bootstrap)..."
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --set 'configs.params.server\.insecure=true' \
  --set server.replicas=1 \
  --set controller.replicas=1 \
  --set repoServer.replicas=1 \
  --set redis-ha.enabled=false \
  --set dex.enabled=false \
  --set notifications.enabled=false \
  --wait --timeout 300s

echo "==> Waiting for ArgoCD to be ready..."
kubectl -n argocd rollout status deployment/argocd-server --timeout=120s

# --- 2. Apply the root Application (app-of-apps) ---
echo "==> Applying root Application..."
cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: hemma-apps
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: ${REPO_URL}
    targetRevision: ${REPO_BRANCH}
    path: apps
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF

# --- 3. Print info ---
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d 2>/dev/null || echo "not-yet-available")

echo ""
echo "========================================="
echo "  hemma-platform bootstrap complete!"
echo "========================================="
echo ""
echo "ArgoCD UI:       https://argocd.rosta.dev"
echo "Username:        admin"
echo "Password:        ${ARGOCD_PASSWORD}"
echo ""
echo "Port-forward ArgoCD (before ingress is ready):"
echo "  kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo ""
echo "Next steps: see README.md for post-bootstrap setup."
echo ""
