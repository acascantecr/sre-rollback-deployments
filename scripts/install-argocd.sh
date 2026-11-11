#!/usr/bin/env bash
# Installs Argo CD v3.5.7 (pinned, manifest vendored in argocd/) in the
# namespace "argocd", creates the lab namespace "rollback-lab" and the
# AppProject that fences the lab, and installs the matching argocd CLI.
# Idempotent. Does not touch the namespace "proyecto".
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
K="microk8s kubectl"
INSTALL="$ROOT/argocd/install-v3.5.7.yaml"

# --- pre-flight: images reachable from this node
if command -v docker >/dev/null 2>&1; then
  grep -oE 'image: [^ ]+' "$INSTALL" | awk '{print $2}' | sort -u | while read -r img; do
    if docker manifest inspect "$img" >/dev/null 2>&1; then
      echo "image ok: $img"
    else
      echo "ERROR: cannot reach image $img" >&2; exit 1
    fi
  done
fi

free -h | sed -n '1,2p'

# --- Argo CD (server-side apply: the CRDs are too large for client-side apply)
$K create namespace argocd --dry-run=client -o yaml | $K apply -f -
$K apply -n argocd --server-side --force-conflicts -f "$INSTALL"

echo "waiting for Argo CD..."
for d in argocd-redis argocd-repo-server argocd-server argocd-dex-server \
         argocd-applicationset-controller argocd-notifications-controller; do
  $K -n argocd rollout status deploy/"$d" --timeout=300s
done
$K -n argocd rollout status statefulset/argocd-application-controller --timeout=300s

# --- lab namespace + AppProject (the fence: only rollback-lab, only this repo)
$K apply -f "$ROOT/namespace.yaml"
$K apply -f "$ROOT/argocd/project.yaml"

# --- argocd CLI: copied from the server pod, so it always matches the server
POD="$($K -n argocd get pod -l app.kubernetes.io/name=argocd-server -o jsonpath='{.items[0].metadata.name}')"
$K -n argocd cp -c argocd-server "$POD":/usr/local/bin/argocd /usr/local/bin/argocd >/dev/null
chmod 0755 /usr/local/bin/argocd
argocd version --client --short

free -h | sed -n '1,2p'
cat <<'EOF'

Argo CD installed. Next:
  1) UI + CLI tunnel (keep this terminal open):
       microk8s kubectl port-forward --address 0.0.0.0 svc/argocd-server -n argocd 8080:443
     UI: https://<node-ip>:8080  (self-signed certificate)
  2) Log in (the password is read into a variable; do not paste it anywhere):
       ARGOCD_PASSWORD="$(microk8s kubectl -n argocd get secret argocd-initial-admin-secret \
         -o jsonpath='{.data.password}' | base64 -d)"
       argocd login localhost:8080 --username admin --password "$ARGOCD_PASSWORD" --insecure
  3) Application: microk8s kubectl apply -f argocd/application.yaml
EOF
