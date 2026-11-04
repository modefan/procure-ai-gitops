# procure-ai-gitops

GitOps repo for [procure-ai](https://github.com/modefan/procure-ai): the local cluster bootstrap, Argo CD's own values, the
app-of-apps chart and the environment values. The Helm charts themselves live in the app repo (`deploy/charts/`), so a chart change
and the code it needs ship in one commit; Argo CD takes the chart from procure-ai at `appRevision` and the values from here.
**No secret is ever committed here**: the bootstrap creates the Kubernetes Secrets from the procure-ai AppHost user secrets.

## Local cluster (k3d)

Needs Docker Desktop running, `k3d`, `kubectl`, `gh` (signed in) and the .NET SDK (`dotnet user-secrets`). Ports 80 and 443 must be
free. Never run the cluster and the Aspire AppHost at the same time: `k3d cluster stop procure` first.

```powershell
./bootstrap/new-cluster.ps1     # k3d cluster `procure` (1 server, 10 GB), CoreDNS rewrite, namespaces procure/observability/argocd
./bootstrap/new-local-ca.ps1    # local CA + certificates in %USERPROFILE%\.procure-ai\local-ca\, TLS Secrets, ConfigMap procure-ca
./bootstrap/new-secrets.ps1     # Secrets in `procure` from the AppHost user secrets (+ ghcr-pull from `gh auth token`)
./tests/Test-BootstrapIsIdempotent.ps1   # second run changes nothing, every Secret exists, DNS rewrite and TLS work
./bootstrap/install-argocd.ps1  # deploy keys, Argo CD, repository Secrets, the root Application: from here Argo CD brings everything up
./tests/Test-FreshCluster.ps1   # DELETES the cluster, runs the four scripts, waits until all is Synced/Healthy/Ready, then Test-Smoke.ps1
```

Every script is safe to run again (`kubectl apply`; files are created once). After changing an AppHost user secret, rerun
`new-secrets.ps1` and restart the pods that use it.

| Script | What it does |
|---|---|
| `bootstrap/new-cluster.ps1` | Creates or starts the cluster (k3s image pinned in `bootstrap/common.ps1`), applies `coredns-custom.yaml`, creates the namespaces, waits for Traefik. |
| `bootstrap/new-local-ca.ps1` | CA (10 years), wildcard `*.procure.localtest.me` and a MongoDB server certificate; Secrets `procure-tls` (Traefik's default certificate through the `default` TLSStore) and `mongo-tls`; ConfigMap `procure-ca` (`<subject hash>.0`, `ca.crt`) in `procure` and `observability`. |
| `bootstrap/new-secrets.ps1` | `procure-postgres`, `procure-rabbitmq`, `procure-redis`, `procure-mongo`, `procure-keycloak`, `procure-debezium`, `procure-api-keys`, `procure-audit-log-reader`, `procure-connection-strings` (one key per AppHost connection name), `ghcr-pull`. Generates missing new values into the user secrets first. |
| `bootstrap/install-argocd.ps1` | Deploy keys (read-only for Argo CD on both repos, write on this repo for procure-ai's publish workflow, whose Actions secret `GITOPS_DEPLOY_KEY` it sets) in `%USERPROFILE%\.procure-ai\deploy-keys\`; Argo CD by Helm (chart version in `apps/values.yaml`, values `argocd/values.yaml`); repository Secrets; the root Application. |
| `bootstrap/remove-cluster.ps1` | Deletes the cluster and all its data (asks first). Keeps the CA. |
| `bootstrap/trust-local-ca.ps1` | Optional, run by hand: trusts the local CA for the current Windows user so browsers accept the certificates (`-Remove` undoes it). |

Hostnames (all `*.localtest.me`, which resolves to 127.0.0.1): `procure.localtest.me` (app), `auth.procure.localtest.me` (Keycloak),
`dashboard.procure.localtest.me`, `argocd.procure.localtest.me`, `mail.procure.localtest.me`. Inside the cluster CoreDNS answers
`auth.procure.localtest.me` with the Traefik service, so pods reach Keycloak by the same URL as the token issuer.

## GitOps: how a commit gets deployed

```
procure-ai push to main -> CI -> publish.yml: app images ghcr.io/modefan/procure-ai-<name>:<sha> (platform images only when infra/
  changed, tag = tree hash of infra/<name>), commit "Deploy procure-ai <sha7>" here
  -> Argo CD (polls every 2-3 min) -> root Application renders apps/ with envs/local/{apps,release}.yaml
       wave -2 argocd         Argo CD manages itself (chart argo-cd, values argocd/values.yaml)
       wave -1 platform       procure-ai deploy/charts/procure-platform @ appRevision + envs/local/platform.yaml
       wave -1 observability  procure-ai deploy/charts/procure-observability (off until plan 07 Task 7)
       wave  0 procure-ai     procure-ai deploy/charts/procure-ai @ appRevision + envs/local/procure-ai.yaml
```

- `envs/local/release.yaml` holds `appRevision`, the full procure-ai commit SHA (the charts are read at that commit and the app images
  carry it as tag), and `platformImageTags` (postgres, keycloak, debezium: the git tree hash of `infra/<name>`, so a deploy that changes
  only app code leaves Postgres, Keycloak and Debezium running). To roll back, set older values here (the images must still be in GHCR;
  retention keeps the newest 15 versions per image and every tag of the last 15 releases).
- App Deployments roll with `maxSurge: 0` (envs/local/procure-ai.yaml): the node has no room for surge pods during a deploy.
- CI writes here with the write deploy key, which is the secret `GITOPS_DEPLOY_KEY` of procure-ai's Environment `gitops` (deployment
  branches: main only); install-argocd.ps1 creates the Environment and sets the secret.
- Every Application syncs automatically (prune, self-heal, server-side apply, retries).
- The platform turns Healthy only after the apps' migrations ran (each Debezium waits for its service's publication). So the root
  does not wait for the platform's health before the apps' wave: Application `platform` carries `procure-ai/wave-gate: synced`, and the
  Application health check in `argocd/values.yaml` lets the next wave start once it is Synced and its sync of the target revision
  succeeded (for every Application, a sync of an older revision does not count, so deploys are ordered too).
  `tests/Test-ApplicationHealth.ps1` runs the check (Lua, `winget install DEVCOM.Lua`) against `tests/health/application-health-cases.lua`.
- Argo CD UI: https://argocd.procure.localtest.me, user `admin`, password in Secret `argocd/argocd-initial-admin-secret`
  (`kubectl --context k3d-procure -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}'`, base64).
- Chart checks for `apps/`: `helm unittest apps` and `helm template root apps -f envs/local/apps.yaml -f envs/local/release.yaml |
  kubeconform -strict -summary -schema-location default -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'`
  (the Application schema from the CRDs catalog).
- `tests/Test-FreshCluster.ps1 -LocalImages` checks a revision before CI published it: build the images in a procure-ai checkout of
  that revision with `deploy/scripts/build-images.ps1 -Tag <appRevision> -Registry ghcr.io/modefan`; the test imports them into k3d.
  `-WatchOnly` skips the delete and bootstrap and only checks the running cluster (after a deploy).
