# procure-ai-gitops

GitOps repo for [procure-ai](https://github.com/modefan/procure-ai): the local cluster bootstrap, Argo CD's own values, the
app-of-apps chart and the environment values. The Helm charts themselves live in the app repo (`deploy/charts/`), so a chart change
and the code it needs ship in one commit; Argo CD takes the chart from procure-ai at `appRevision` and the values from here.
**No secret is ever committed here**: the bootstrap creates the Kubernetes Secrets from the procure-ai AppHost user secrets.

## Local cluster (k3d)

Needs Docker Desktop running, `k3d`, `kubectl`, `gh` (signed in) and the .NET SDK (`dotnet user-secrets`). Ports 80, 443 and 6550 on
127.0.0.1 must be free: the cluster publishes the ingress and the Kubernetes API on the PC's loopback address only, never on its network
interfaces (checked by `new-cluster.ps1`, `Test-BootstrapIsIdempotent.ps1` and `Test-Smoke.ps1`). Never run the cluster and the Aspire AppHost at the same time: `k3d cluster stop procure` first.

```powershell
./bootstrap/new-cluster.ps1     # k3d cluster `procure` (1 server, 10 GiB), CoreDNS rewrite, namespaces procure/observability/argocd
./bootstrap/new-local-ca.ps1    # local CA + certificates in %USERPROFILE%\.procure-ai\local-ca\, TLS Secrets, ConfigMap procure-ca
./bootstrap/new-secrets.ps1     # Secrets in `procure` from the AppHost user secrets
./tests/Test-BootstrapIsIdempotent.ps1   # second run changes nothing, every Secret exists, DNS rewrite and TLS work
./bootstrap/install-argocd.ps1  # deploy keys, Argo CD, repository Secrets, the root Application: from here Argo CD brings everything up
./tests/Test-FreshCluster.ps1   # DELETES the cluster, runs the four scripts, waits until all is Synced/Healthy/Ready, then Test-Smoke.ps1
```

Every script is safe to run again (`kubectl apply`; files are created once). After changing an AppHost user secret, rerun
`new-secrets.ps1` and restart the pods that use it. `new-secrets.ps1` keeps keys it no longer writes (pods of the previous revision may
still use them); after Argo CD synced and rolled a revision that dropped keys, run `new-secrets.ps1 -Prune` (procure-ai
`docs/kubernetes.md`, "Changing the shape of a Secret").

| Script | What it does |
|---|---|
| `bootstrap/new-cluster.ps1` | Creates or starts the cluster (k3s image pinned in `bootstrap/common.ps1`), applies `coredns-custom.yaml`, creates the namespaces, waits for Traefik. |
| `bootstrap/new-local-ca.ps1` | CA (10 years, name-constrained to `localtest.me`, MongoDB's in-cluster names and 127.0.0.1: it cannot vouch for any other site; an older unconstrained CA is replaced), wildcard `*.procure.localtest.me` and a MongoDB server certificate; Secrets `procure-tls` (Traefik's default certificate through the `default` TLSStore) and `mongo-tls`; ConfigMap `procure-ca` (`<subject hash>.0`, `ca.crt`) in `procure` and `observability`. |
| `bootstrap/new-secrets.ps1` | `procure-postgres`, `procure-rabbitmq`, `procure-redis`, `procure-mongo`, `procure-keycloak`, `procure-debezium`, `procure-db-roles` (every service's own database role and user, plan 08 Task 4), `procure-api-keys`, `procure-connection-strings` (one key per AppHost connection name, each database as its service's own role) (no `ghcr-pull` any more: the GHCR packages are public, both clusters pull anonymously and a run removes an old one); in `observability` `procure-keycloak` with only `dashboard-secret` (the Aspire dashboard's client). Generates missing new values into the user secrets first. |
| `bootstrap/install-argocd.ps1` | Deploy keys (read-only for Argo CD on both repos, write on this repo for procure-ai's publish workflow, whose Actions secret `GITOPS_DEPLOY_KEY` it sets) in `%USERPROFILE%\.procure-ai\deploy-keys\`; Argo CD by Helm (chart version in `apps/values.yaml`, values `argocd/values.yaml`); repository Secrets; the root Application. |
| `bootstrap/remove-cluster.ps1` | Deletes the cluster and all its data (asks first). Keeps the CA. |
| `bootstrap/trust-local-ca.ps1` | Optional, run by hand: trusts the local CA for the current Windows user so browsers accept the certificates (`-Remove` undoes it). |

Hostnames (all `*.localtest.me`, which resolves to 127.0.0.1): `procure.localtest.me` (app), `auth.procure.localtest.me` (Keycloak),
`dashboard.procure.localtest.me`, `argocd.procure.localtest.me`, `mail.procure.localtest.me`. Inside the cluster CoreDNS answers
`auth.procure.localtest.me` with the Traefik service, so pods reach Keycloak by the same URL as the token issuer.

## Hosted VM (Contabo)

The live demo runs on a Contabo Cloud VPS with k3s, built by Terraform in `infra/hosted/` (the adopted VPS reinstalled with cloud-init,
Contabo's firewall, the Cloudflare DNS records) and bootstrapped through an SSH tunnel by `bootstrap/hosted/`:
`new-hosted-cluster.ps1` (plan, money guard, apply, kubeconfig), `hosted/install-cert-manager.ps1` (Traefik on host ports 80/443 so it sees the
visitor's address, the https redirect and HSTS, cert-manager, the Let's Encrypt certificate for procure, auth and dashboard.daleabels.com;
staging unless `-Production`), `new-local-ca.ps1 -Environment hosted` (the
internal CA for MongoDB's TLS), `new-secrets.ps1 -Environment hosted` and `install-argocd.ps1 -Environment hosted`, which then brings up
`envs/hosted/` (the public demo at <https://procure.daleabels.com>). `bootstrap/hosted/Test-HostBaseline.ps1` checks the VM's security
baseline and `tests/Test-PublicSurface.ps1` what the internet sees; `Test-Smoke.ps1`, `Test-FreshCluster.ps1 -WatchOnly`,
`Test-RestartKeepsData.ps1 -Reboot` and `Test-WalSlotsAdvance.ps1` take `-Environment hosted`. Costs, how to cancel and every step:
procure-ai `docs/hosting.md`.

`.github/workflows/uptime.yml` is the repo's only workflow (no CI here): it checks the gateway's `/health/ready`, the web app, Keycloak's
realm and the demo switch on the public hosts, and that each host's Let's Encrypt certificate has at least 21 days left, and fails
(GitHub e-mails the owner) when one is not so. It runs every 30 minutes (free for a public repo; it ran once a day while the repo was
private, plan 08 fix wave ruling R2).

Maintenance of the VM (procure-ai `docs/hosting.md` has the runbooks): `bootstrap/hosted/upgrade-k3s.ps1` (plans a k3s patch upgrade: the
embedded containerd, runc and Traefik versions; `-Apply` upgrades, re-fetches the kubeconfig and reruns the baseline),
`new-hosted-cluster.ps1 -KubeconfigOnly`, `new-hosted-cluster.ps1 -Import` (adopts the existing VM, firewall, key and DNS records into a
lost Terraform state without a reinstall) and `bootstrap/hosted/backup-hosted.ps1` (an off-PC backup copy of the secrets exists; its location and
contents are in the operator's private runbook, and the script reads them from a private file outside every repo; it mirrors and
SHA-256-checks the copy, `-Check` only compares).

**Before every push here that changes `envs/`, `apps/` or `argocd/`: `./tests/Test-RenderEnvs.ps1`.** This repo has no CI, so nothing
else renders the values before Argo CD does on the cluster (for `envs/hosted`, the public demo). It renders the app of apps, procure-ai's
three charts at each environment's `appRevision` (or `-AppRef WORKTREE -AppRepo <procure-ai worktree>` for an unpushed chart change) and
Argo CD's own chart, each through `kubeconform -strict`. procure-ai's CI renders the same environments against every procure-ai commit.

## GitOps: how a commit gets deployed

```
procure-ai push to main -> CI -> publish.yml: app images ghcr.io/modefan/procure-ai-<name>:<sha> (platform images only when infra/
  changed, tag = tree hash of infra/<name>), commit "Deploy procure-ai <sha7>" here
  -> Argo CD (polls every 2-3 min) -> root Application renders apps/ with envs/local/{apps,release}.yaml
       wave -2 argocd         Argo CD manages itself (chart argo-cd, values argocd/values.yaml)
       wave -1 platform       procure-ai deploy/charts/procure-platform @ appRevision + envs/local/platform.yaml
       wave -1 observability  procure-ai deploy/charts/procure-observability @ appRevision + envs/local/observability.yaml
       wave  0 procure-ai     procure-ai deploy/charts/procure-ai @ appRevision + envs/local/procure-ai.yaml
```

- `envs/local/release.yaml` holds `appRevision`, the full procure-ai commit SHA (the charts are read at that commit and the app images
  carry it as tag), and `platformImageTags` (postgres, keycloak, debezium: the git tree hash of `infra/<name>`, so a deploy that changes
  only app code leaves Postgres, Keycloak and Debezium running). To roll back, set older values here (the images must still be in GHCR;
  retention keeps the newest 15 versions per image and every tag of the last 15 releases).
- App Deployments roll with `maxSurge: 0` (envs/local/procure-ai.yaml): the node has no room for surge pods during a deploy.
- CI writes here with the write deploy key, which is the secret `GITOPS_DEPLOY_KEY` of procure-ai's Environment `gitops` (deployment
  branches: main only); install-argocd.ps1 creates the Environment and sets the secret. procure-ai's weekly `retention` workflow only
  reads this repo, with the read-only deploy key `procure-ai retention workflow (read-only)` (secret `GITOPS_READ_DEPLOY_KEY` of the
  Environment `gitops-read`, main only; plan 08 Task 6).
- Every Application syncs automatically (prune, self-heal, server-side apply, 3 retries 10 s, 20 s and 40 s apart). A sync whose retries
  are spent (phase `Failed` or `Error`, e.g. a failing migration) makes the root Application `Degraded` (plan 08 ruling 9).
- The platform turns Healthy only after the apps' migrations ran (each Debezium waits for its service's publication). So the root
  does not wait for the platform's health before the apps' wave: Application `platform` carries `procure-ai/wave-gate: synced`, and the
  Application health check in `argocd/values.yaml` lets the next wave start once it is Synced and its sync of the target revision
  succeeded (for every Application, a sync of an older revision does not count, so deploys are ordered too).
  `tests/Test-ApplicationHealth.ps1` runs the check (Lua, `winget install DEVCOM.Lua`) against `tests/health/application-health-cases.lua`.
- Argo CD UI: https://argocd.procure.localtest.me, user `admin`, password in Secret `argocd/argocd-initial-admin-secret`
  (`kubectl --context k3d-procure -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}'`, base64).
  `argocd.adminEnabled` and `argocd.ingressEnabled` in `envs/<env>/apps.yaml` (default on, as local) turn the admin user and the ingress
  off for a public host (plan 08 ruling 4); the argocd Application and `install-argocd.ps1` both apply them. Hosted (plan 08c Task 1):
  both on; the ingress is https://argocd.daleabels.com behind a Keycloak gate (oauth2-proxy, realm `ops`, group `argocd-admins` only;
  `envs/hosted/argocd.yaml`), the admin login answers 403 there and works only through the tunnel (`bootstrap/hosted/open-argocd.ps1 -Tunnel`).
- Chart checks for `apps/`: `helm unittest apps` and `helm template root apps -f envs/local/apps.yaml -f envs/local/release.yaml |
  kubeconform -strict -summary -schema-location default -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'`
  (the Application schema from the CRDs catalog).
- `tests/Test-FreshCluster.ps1 -LocalImages` checks a revision before CI published it: build the images in a procure-ai checkout of
  that revision with `deploy/scripts/build-images.ps1 -Tag <appRevision> -Registry ghcr.io/modefan`; the test imports them into k3d.
  `-WatchOnly` skips the delete and bootstrap and only checks the running cluster (after a deploy).
- `tests/Test-Smoke.ps1` (also the last step of Test-FreshCluster): gateway and Keycloak through Traefik, demo login, seeded data with the
  admin key, the observability Application, the dashboard's Keycloak sign-in (Tom refused, the admin with `dashboard-viewer` let in),
  its telemetry API answering 404, and that a pod in `procure` cannot reach the gateway or Keycloak directly with a spoofed
  `X-Forwarded-For` (only through Traefik; plan 08 ruling 5).
- `tests/Test-Dashboard.ps1 [-Environment hosted]` (plan 08b; also run by Test-FreshCluster after Test-Smoke): the Aspire dashboard as an
  operator uses it. Fresh telemetry through the gateway (admin key), Blazor's WebSocket Origin check (own Origin passes, a foreign one and
  http:// get 403, on `/_blazor` and `/_Blazor`), then Microsoft Edge (playwright-core, `tests/dashboard/`, installed by the first run)
  signs in as the demo admin, loads Structured logs and Traces three times each (rows within 20 s every time) and needs rows newer than 10
  minutes from requests-api (logs) and the gateway and requests-api (traces; some recent trace on each must start at the gateway). `-NoNudge` blocks the blank-table workaround of procure-ai's
  observability chart, to see whether a new dashboard release still needs it. **Run it after every push or deploy that reaches a
  cluster** (CLAUDE.md "Operating the live system"): `Test-FreshCluster.ps1 -Environment hosted -WatchOnly` includes it.
- `tests/Test-LocalCa.ps1` (no cluster needed): `new-local-ca.ps1 -FilesOnly` into a temp folder; the CA's name constraints, both leaves
  verify, a certificate for any other name signed by the same CA does not, an old unconstrained CA is replaced.
- `tests/Test-Upgrade.ps1` (plan 07 Review Focus 2): deploys two throwaway procure-ai revisions by a helm parameter on the root
  Application (branches `test-upgrade/*`, only requests-api built, the other app images retagged in the node): one with an empty
  migration (every `<name>-migrate` Job reruns and finishes before the new pods start) and one whose Requests migration fails (the old
  pods keep serving, the sync does not succeed). Always restores `release.yaml`'s revision and deletes the branches. `-BaseRevision`
  starts the test revisions from another commit that changes no app code.
- `tests/Test-RestartKeepsData.ps1` (Review Focus 3): row, document and replication-slot counts before and after `k3d cluster
  stop/start` and deleted postgres-0 / mongo-0 pods, then a new request must reach the data change log within 30 s.
- The procure-ai end-to-end suite runs against the cluster too: see procure-ai `docs/kubernetes.md`.

## Licence

[MIT](LICENSE).
