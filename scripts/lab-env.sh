#!/usr/bin/env bash
# Stops or starts the rollback lab (Argo CD + namespace rollback-lab) to free
# memory, e.g. to run the final project alone and switch back later.
# Nothing is deleted: Argo CD, its Applications, the AppProject and the lab
# manifests stay; only the pods go away (Argo CD uses ~800 MiB).
#
# Usage: scripts/lab-env.sh -e stop|start|status
#   -e stop    stop Argo CD FIRST (otherwise its selfHeal would scale the lab
#              app back up), then rollback-lab; also kills the lab's
#              port-forwards (8080 Argo CD UI, 8081 lab app).
#   -e start   bring rollback-lab back, then Argo CD, with the same replica
#              counts as before. The port-forwards are NOT restarted (see the
#              commands printed at the end).
#   -e status  what is running in both namespaces + host memory.
#
# Same mechanism as proyecto_sre/scripts/Stop_start_environment.sh: on "stop"
# each workload gets the annotation lab-previous-replicas=<n>; "start" reads it
# and removes it; a second "stop" never overwrites it with 0.
# Never touches the namespace "proyecto".
#
# Switch to the final project:   scripts/lab-env.sh -e stop
#                                /home/proyecto/proyecto_sre/scripts/Stop_start_environment.sh -e start
# Switch to the lab:             /home/proyecto/proyecto_sre/scripts/Stop_start_environment.sh -e stop
#                                scripts/lab-env.sh -e start
set -uo pipefail

STOP_ORDER=(argocd rollback-lab)     # Argo CD first: no selfHeal while stopping
START_ORDER=(rollback-lab argocd)    # lab app first, then Argo CD watches again
K="microk8s kubectl"
ACTION=""

usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; }

while getopts "e:h" opt; do
  case "$opt" in
    e) ACTION="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
case "$ACTION" in stop|start|status) ;; *) usage >&2; exit 2 ;; esac

api_up() { $K get --raw /readyz >/dev/null 2>&1; }
ns_exists() { $K get ns "$1" >/dev/null 2>&1; }

# "name replicas saved" per workload ("<none>" when the annotation is missing)
workloads() {
  $K -n "$1" get "$2" --no-headers \
    -o custom-columns='NAME:.metadata.name,REPLICAS:.spec.replicas,SAVED:.metadata.annotations.lab-previous-replicas' \
    2>/dev/null
}

wait_pods_gone() {
  local ns="$1" n=0
  for _ in $(seq 1 60); do
    n=$($K -n "$ns" get pods --no-headers \
        --field-selector='status.phase!=Succeeded,status.phase!=Failed' 2>/dev/null | wc -l)
    if [ "$n" -eq 0 ]; then echo "  all pods of $ns are gone"; return 0; fi
    sleep 3
  done
  echo "  WARNING: $n pod(s) of $ns still terminating after 3 minutes"
}

do_stop() {
  api_up || { echo "Cluster API not reachable: nothing to stop."; return 0; }
  local ns kind name cur saved
  for ns in "${STOP_ORDER[@]}"; do
    ns_exists "$ns" || { echo "== namespace $ns: not found, skipped"; continue; }
    echo "== namespace $ns"
    for kind in deployments statefulsets; do
      while read -r name cur saved; do
        [ -n "$name" ] || continue
        if [ "$cur" -gt 0 ] 2>/dev/null; then
          $K -n "$ns" annotate "$kind/$name" "lab-previous-replicas=$cur" --overwrite </dev/null >/dev/null
          $K -n "$ns" scale "$kind/$name" --replicas=0 </dev/null >/dev/null
          echo "  stopped $kind/$name (was $cur)"
        else
          echo "  $kind/$name already at 0"
        fi
      done < <(workloads "$ns" "$kind")
    done
    wait_pods_gone "$ns"
  done
  # The tunnels would only print errors with their pods gone.
  pkill -f 'port-forward svc/argocd-server' 2>/dev/null && echo "  port-forward 8080 (Argo CD) stopped"
  pkill -f 'port-forward svc/sre-rollback-service' 2>/dev/null && echo "  port-forward 8081 (lab app) stopped"
  echo "Rollback lab stopped. Nothing was deleted."
  free -h | sed -n '1,2p'
}

do_start() {
  api_up || { echo "ERROR: cluster API not reachable. Start MicroK8s first (e.g. Stop_start_environment.sh -e start)." >&2; exit 1; }
  local ns kind name cur saved target
  for ns in "${START_ORDER[@]}"; do
    ns_exists "$ns" || { echo "== namespace $ns: not found, skipped"; continue; }
    echo "== namespace $ns"
    for kind in statefulsets deployments; do
      local started=()
      while read -r name cur saved; do
        [ -n "$name" ] || continue
        if [ "$cur" -gt 0 ] 2>/dev/null; then
          echo "  $kind/$name already running ($cur)"; continue
        fi
        target="$saved"
        if [ -z "$target" ] || [ "$target" = "<none>" ]; then
          target=1
          echo "  WARNING: no saved replica count for $kind/$name, using 1"
        fi
        $K -n "$ns" scale "$kind/$name" --replicas="$target" </dev/null >/dev/null
        $K -n "$ns" annotate "$kind/$name" lab-previous-replicas- </dev/null >/dev/null 2>&1
        echo "  started $kind/$name ($target)"
        started+=("$kind/$name")
      done < <(workloads "$ns" "$kind")
      for name in "${started[@]:-}"; do
        [ -n "$name" ] || continue
        $K -n "$ns" rollout status "$name" --timeout=300s </dev/null >/dev/null \
          && echo "  ready: $name" || echo "  WARNING: $name not ready yet"
      done
    done
  done
  cat <<'EOF'
Rollback lab started. Tunnels (each in its own terminal, or append ">/dev/null 2>&1 &"):
  microk8s kubectl port-forward --address 0.0.0.0 svc/argocd-server -n argocd 8080:443
  microk8s kubectl -n rollback-lab port-forward svc/sre-rollback-service 8081:80 --address 0.0.0.0
Then log in again if needed: argocd login localhost:8080 --username admin --password "$ARGOCD_PASSWORD" --insecure
EOF
  free -h | sed -n '1,2p'
}

do_status() {
  local ns
  if api_up; then
    for ns in "${START_ORDER[@]}"; do
      echo "== namespace $ns"
      ns_exists "$ns" && $K -n "$ns" get deploy,sts 2>/dev/null || echo "  (not found)"
      echo
    done
    echo "== proyecto (final project): $($K -n proyecto get pods --no-headers 2>/dev/null | grep -c Running) pod(s) Running"
  else
    echo "Cluster API not reachable (MicroK8s stopped?)."
  fi
  free -h | sed -n '1,2p'
}

case "$ACTION" in
  stop) do_stop ;;
  start) do_start ;;
  status) do_status ;;
esac
