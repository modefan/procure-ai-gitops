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
```

Every script is safe to run again (`kubectl apply`; files are created once). After changing an AppHost user secret, rerun
`new-secrets.ps1` and restart the pods that use it.

| Script | What it does |
|---|---|
| `bootstrap/new-cluster.ps1` | Creates or starts the cluster (k3s image pinned in `bootstrap/common.ps1`), applies `coredns-custom.yaml`, creates the namespaces, waits for Traefik. |
| `bootstrap/new-local-ca.ps1` | CA (10 years), wildcard `*.procure.localtest.me` and a MongoDB server certificate; Secrets `procure-tls` (Traefik's default certificate through the `default` TLSStore) and `mongo-tls`; ConfigMap `procure-ca` (`<subject hash>.0`, `ca.crt`) in `procure` and `observability`. |
| `bootstrap/new-secrets.ps1` | `procure-postgres`, `procure-rabbitmq`, `procure-redis`, `procure-mongo`, `procure-keycloak`, `procure-debezium`, `procure-api-keys`, `procure-audit-log-reader`, `procure-connection-strings` (one key per AppHost connection name), `ghcr-pull`. Generates missing new values into the user secrets first. |
| `bootstrap/remove-cluster.ps1` | Deletes the cluster and all its data (asks first). Keeps the CA. |
| `bootstrap/trust-local-ca.ps1` | Optional, run by hand: trusts the local CA for the current Windows user so browsers accept the certificates (`-Remove` undoes it). |

Hostnames (all `*.localtest.me`, which resolves to 127.0.0.1): `procure.localtest.me` (app), `auth.procure.localtest.me` (Keycloak),
`dashboard.procure.localtest.me`, `argocd.procure.localtest.me`, `mail.procure.localtest.me`. Inside the cluster CoreDNS answers
`auth.procure.localtest.me` with the Traefik service, so pods reach Keycloak by the same URL as the token issuer.
