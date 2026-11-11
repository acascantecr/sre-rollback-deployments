#!/usr/bin/env bash
# Removes ONLY what the rollback lab created. Never touches the namespace
# "proyecto" (final project).
#
# Usage: scripts/lab-cleanup.sh            # app, AppProject, repo access, namespace rollback-lab
#        scripts/lab-cleanup.sh --argocd   # the above + uninstall Argo CD completely
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
K="microk8s kubectl"
UNINSTALL_ARGOCD=false
[ "${1:-}" = "--argocd" ] && UNINSTALL_ARGOCD=true

echo "Will delete: Application sre-rollback-app, AppProject rollback-lab, namespace rollback-lab"
$UNINSTALL_ARGOCD && echo "             + Argo CD (namespace argocd, its CRDs and cluster roles)"
echo "Will NOT touch: namespace proyecto"
read -r -p "Continue? [y/N] " ok
[ "$ok" = "y" ] || [ "$ok" = "Y" ] || { echo "aborted"; exit 0; }

if $K get crd applications.argoproj.io >/dev/null 2>&1; then
  $K -n argocd delete application sre-rollback-app --ignore-not-found
  $K -n argocd delete appproject rollback-lab --ignore-not-found
fi

$K delete namespace rollback-lab --ignore-not-found

if $UNINSTALL_ARGOCD; then
  $K delete -n argocd -f "$ROOT/argocd/install-v3.5.7.yaml" --ignore-not-found
  $K delete namespace argocd --ignore-not-found
  rm -f /usr/local/bin/argocd
fi

echo
echo "Lab removed. Optional, by hand:"
echo "  - stop any 'kubectl port-forward' still running (jobs; kill %N)"
$K get pods -n proyecto --no-headers | awk '{print $2}' | sort | uniq -c \
  | sed 's/^/  proyecto pods READY: /'
