# Ejercicio 18 en el nodo del proyecto (sin tocar `proyecto`)

Todo vive en el namespace **`rollback-lab`** (fijo en cada manifiesto) y ArgoCD queda
encerrado en el AppProject **`rollback-lab`**: solo puede leer este repo, solo despliega en
`rollback-lab` y solo crea Deployments, Services y ConfigMaps.

Repo: `https://github.com/acascantecr/sre-rollback-deployments` (público; ArgoCD lo lee sin
credenciales). Para **subir** cambios sí necesitas tu propia autenticación de github.com.

`K` = `microk8s kubectl` (o el alias `kubectl`). Ejecutar todo desde la raíz de este repo.

## Antes de empezar

```bash
free -h                                   # anotar memoria disponible
microk8s kubectl -n proyecto exec mariadb-0 -- sh -c \
  'mariadb-dump -uroot -p"$MARIADB_ROOT_PASSWORD" airline' > /root/airline-backup-$(date +%F).sql
```

## Fase 1 — Manifiestos versionados

Ya están en `v1/` y `v2/` (con `namespace: rollback-lab`, requests/limits y probes).

```bash
git add namespace.yaml v1 v2 argocd scripts GUIA-LAB.md
git commit -m "feat: v1 (stable) and v2 (broken image) manifests, Argo CD project and scripts"
git push origin main
```

## Fases 2–4 — Kubernetes nativo (sin ArgoCD)

Igual que el ejercicio, añadiendo `-n rollback-lab` a **todo** comando sin archivo.

```bash
microk8s kubectl apply -f namespace.yaml
microk8s kubectl apply -f v1/
microk8s kubectl -n rollback-lab rollout status deployment/sre-rollback-app
microk8s kubectl -n rollback-lab port-forward svc/sre-rollback-service 8081:80 --address 0.0.0.0 &
curl -s http://localhost:8081 | grep -oE 'Version [0-9.]+'          # Version 1.0

# Fase 3: versión rota
microk8s kubectl apply -f v2/
microk8s kubectl -n rollback-lab rollout status deployment/sre-rollback-app --timeout=60s || echo "falló, como se esperaba"
microk8s kubectl -n rollback-lab get pods -l app=sre-rollback-app   # ImagePullBackOff; el pod v1 sigue sirviendo

# Fase 4: rollback nativo
microk8s kubectl -n rollback-lab rollout undo deployment/sre-rollback-app
microk8s kubectl -n rollback-lab rollout status deployment/sre-rollback-app --timeout=180s
microk8s kubectl -n rollback-lab rollout history deployment/sre-rollback-app
```

En los bloques `watch`, `describe`, `get events` y `get rs` del ejercicio: añadir `-n rollback-lab`.

## Fase 5 — ArgoCD

```bash
scripts/install-argocd.sh                     # ArgoCD v3.5.7 + AppProject + CLI (~3-5 min)
free -h                                       # comparar con la medición inicial

# Terminal aparte (dejarla abierta):
microk8s kubectl port-forward --address 0.0.0.0 svc/argocd-server -n argocd 8080:443
# UI: https://9.60.140.183:8080 (certificado autofirmado)

ARGOCD_PASSWORD="$(microk8s kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d)"
argocd login localhost:8080 --username admin --password "$ARGOCD_PASSWORD" --insecure

# Repo público en github.com: ArgoCD lo lee sin credenciales (nada que registrar).
microk8s kubectl apply -f argocd/application.yaml
argocd app get sre-rollback-app               # Synced / Healthy (path v1)
```

Simular la versión rota (como el ejercicio):

```bash
microk8s kubectl patch application sre-rollback-app -n argocd --type=merge \
  -p='{"spec":{"source":{"path":"v2"}}}'
argocd app sync sre-rollback-app
argocd app wait sre-rollback-app --health --timeout 60 || echo "Degraded, como se esperaba"
```

### Métodos de rollback

**Método 1 (Git / declarativo, el preferido):** funciona con el auto-sync activo.

```bash
microk8s kubectl patch application sre-rollback-app -n argocd --type=merge \
  -p='{"spec":{"source":{"path":"v1"}}}'
```

**Métodos 2 (UI) y 3 (CLI):** ArgoCD **rechaza** `rollback` mientras el auto-sync está
activo. Desactivarlo primero:

```bash
argocd app set sre-rollback-app --sync-policy none
argocd app history sre-rollback-app           # elegir a ojo el ID del último despliegue de v1
argocd app rollback sre-rollback-app <ID>     # o UI: History and Rollback -> Rollback
```

Después del rollback la app queda **OutOfSync** (Git sigue diciendo `v2`): es lo esperado y
es la lección del ejercicio. Para volver al estado declarativo: método 1 y
`argocd app set sre-rollback-app --sync-policy automated`.

## Verificar que el proyecto no se tocó (en cualquier momento)

```bash
microk8s kubectl -n proyecto get pods          # todo 1/1 Running, RESTARTS sin cambios
scripts/simulate-incident.sh status            # desde el repo proyecto_sre: (none) en alertas
```

## Limpieza

```bash
scripts/lab-cleanup.sh            # app, AppProject, namespace rollback-lab
scripts/lab-cleanup.sh --argocd   # además desinstala ArgoCD (recomendado antes de la demo final)
```

Luego, a mano: detener los `port-forward` que sigan corriendo (`jobs`, `kill %N`).
