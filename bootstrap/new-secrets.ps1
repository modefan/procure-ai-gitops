#Requires -Version 7.4
<#
.SYNOPSIS
    Creates the Kubernetes Secrets in namespaces `procure` and `observability` from the AppHost user secrets (the one source of every secret, plan 07 ruling 5).
.DESCRIPTION
    Reads `dotnet user-secrets` of the AppHost (UserSecretsId procure-ai-apphost). Values that are new in plan 07 or plan 08 and not there
    yet (keycloak-db-password, keycloak-dashboard-secret, debezium-mongo-password; the per-service database passwords db-<service>-password,
    db-<service>-cdc-password and db-assistant-mongo-password of plan 08 ruling 6) are generated once (32 letters and digits) and written to
    the user secrets first, so the AppHost and the cluster share them. Every Secret is applied server-side, so a second run changes
    nothing. Rerun this script after changing a user secret, then restart the pods that use it.
    Keys a Secret has on the cluster but this script no longer writes (a secret-shape change, e.g. plan 08 Task 4 dropped
    procure-debezium/postgres-password) are KEPT by default, with their live values: pods of the previous revision may still reference
    them until Argo CD has synced and rolled the new one, and a pod that restarts into a missing key hangs in CreateContainerConfigError
    (a StatefulSet then never rolls past it). Run with -Prune only after that rollout to remove them, and Secrets this script retired
    (procure-audit-log-reader). The order: docs/kubernetes.md in procure-ai, "Changing the shape of a Secret".
    Prints only object and key names, never values.

    Secrets (keys):
      procure-postgres           password
      procure-rabbitmq           username, password
      procure-redis              password
      procure-mongo              username, password, keyfile
      procure-keycloak           admin-username, admin-password, demo-password, gateway-secret, internal-secret, access-admin-secret,
                                 demo-login-secret, dashboard-secret, db-password, automation-client-secret (the master-realm client
                                 procure-automation the keycloak-config Job and kcadm sign in with; plan 08b Task 4 fix round 1)
      procure-debezium           mongo-password (debezium-mongo's MongoDB user)
      procure-db-roles           <service>-password (accessdb ... requestsdb, suppliers on MongoDB), <service>-cdc-password (each Postgres
                                 database a Debezium reads), assistant-mongo-password, audit-log-reader-password: what the platform's
                                 db-roles Job sets on the roles and users, and what each Debezium replicates with
      procure-api-keys           admin-api-key, admin-api-key-sha256, simulator-api-key, supplier-webhook-secret
      procure-connection-strings one key per AppHost connection name (ConnectionStrings__<name>): the Postgres databases, suppliersdb,
                                 assistantchatdb, rabbitmq, redis, auditlog; in-cluster host names; MongoDB with tls=true. Each
                                 database as its service's own role or user (<service>_app), never the superuser or root
      procure-ai-provider        api-key: hosted only (plan 08 Task 12), the Azure Foundry key of the Assistant (AI__ApiKey, envs/hosted/
                                 procure-ai.yaml), from the user env var AZURE_FOUNDRY_API_KEY on every run (rotate: change the env var, rerun,
                                 restart assistant-api); the local cluster runs the Fake provider and has no such Secret
      ghcr-pull                  kubernetes.io/dockerconfigjson for ghcr.io: local from `gh auth token` (plan 07 ruling 7); hosted from
                                 the user env var GHCR_READ_TOKEN (classic PAT, read:packages only; plan 08 D4)
    In namespace observability (a pod reads Secrets of its own namespace only):
      procure-keycloak           dashboard-secret only (the Aspire dashboard's Keycloak client aspire-dashboard)
      aspire-dashboard-direct-basic-auth  kubernetes.io/basic-auth: username operator, password operator-dashboard-token (the break-glass
                                 dashboard's login in front of it, Traefik basicAuth; plan 08b Task 4)

    The operator's direct access (plan 08b Task 4; procure-ai docs/hosting.md "Operate from the browser"): every tool has its own long
    generated login, kept only in the store, DEMO PASSWORDS.txt and these Secrets (bootstrap/hosted/Get-OperatorLogin.ps1 reads them back):
      procure (added keys)       procure-db-roles operator-reader-postgres-password, operator-reader-mongo-password; procure-redis
                                 operator-reader-password; procure-rabbitmq operator-password; procure-keycloak operator-password,
                                 operator-totp-base32 (Keycloak's master-realm user `operator`)
      operator (namespace)       operator-pgadmin (password, totp-base32, reader-password), operator-mongo-ui (password,
                                 reader-password), operator-redis-insight (reader-password, encryption-key),
                                 operator-redis-insight-basic-auth (kubernetes.io/basic-auth: username, password)
    The TOTP secrets are Base32 (an authenticator app takes them as they are; Get-OperatorLogin.ps1 prints the current code).

    Argo CD's public host (hosted only, plan 08c Task 1, ruling R9): the Keycloak gate in front of it (oauth2-proxy, envs/hosted/argocd.yaml)
    encrypts its session cookie with
      argocd (namespace)         argocd-gate (cookie-secret: 32 letters and digits, the AES-256 key; parameter argocd-gate-cookie-secret)
    Rotating it signs everyone out of the gate (they sign in again with Keycloak); restart deploy/argocd-gate after a new value.

    -Environment hosted (plan 08 ruling 11): the same Secrets on the hosted VM (bootstrap/hosted/, through the SSH tunnel), from a separate
    user-secrets store `procure-ai-hosted` that shares no value with the AppHost. Every value is generated there on the first run (32
    letters and digits; the admin API key 64, its SHA-256 derived from it; the MongoDB keyfile 48 random bytes in base64) and kept, so a
    second run changes nothing. Rotate a value by removing it from that store (dotnet user-secrets remove --id procure-ai-hosted
    Parameters:<name>) and running the script again, then restart the pods that use it.

    Every run also copies every value of the store into DEMO PASSWORDS.txt (Sync-DemoPasswordSection in common.ps1; section "procure-ai
    hosted (Contabo) secrets" or "procure-ai local: all AppHost user secrets"), so a generated or rotated value is never only in the store.
    The file is rewritten only when a value changed, and no .bak copy stays behind.
#>
[CmdletBinding()]
param(
    # local: the k3d cluster and the AppHost user secrets. hosted: the VM through the SSH tunnel and the procure-ai-hosted user secrets.
    [ValidateSet('local', 'hosted')]
    [string] $Environment = 'local',
    # The GitHub account whose token pulls the GHCR images.
    [string] $GhcrUser = 'modefan',
    # Remove the keys (and Secrets) this script no longer writes. Only after Argo CD synced and rolled every pod that used them.
    [switch] $Prune
)

. (Join-Path $PSScriptRoot 'common.ps1')
Select-ProcureCluster $Environment
Assert-ClusterReachable
$hosted = $Environment -eq 'hosted'
$storeName = if ($hosted) { "hosted user secrets ($UserSecretsId)" } else { "AppHost user secrets ($UserSecretsId)" }

$secrets = Read-UserSecrets

# The services' own database roles (plan 08 ruling 6; infra/postgres/roles.sql, infra/mongo/users.js): Postgres services, the ones a
# Debezium reads (a <service>_cdc role each), and the MongoDB-only service.
$postgresServices = 'access', 'approvals', 'assistant', 'audit', 'budgets', 'invoicing', 'purchasing', 'requests'
$capturedServices = 'access', 'approvals', 'assistant', 'budgets', 'invoicing', 'purchasing', 'requests'
$databasePasswords = @($postgresServices + 'suppliers' | ForEach-Object { "db-$_-password" }) +
    @($capturedServices | ForEach-Object { "db-$_-cdc-password" }) + 'db-assistant-mongo-password'

$required = 'postgres-password', 'rabbitmq-password', 'redis-password', 'mongo-password', 'mongo-keyfile-content',
    'keycloak-admin-password', 'keycloak-demo-password', 'keycloak-gateway-secret', 'keycloak-internal-secret',
    'keycloak-access-admin-secret', 'keycloak-demo-login-secret', 'keycloak-dashboard-secret', 'keycloak-db-password',
    'debezium-mongo-password', 'admin-api-key', 'admin-api-key-sha256', 'simulator-api-key',
    'supplier-webhook-secret', 'audit-log-reader-password'
$required += $databasePasswords
# The operator's logins and read-only database users (plan 08b Task 4), generated in both stores.
$operatorParameters = 'operator-pgadmin-password', 'operator-pgadmin-totp-base32', 'operator-reader-postgres-password',
    'operator-reader-mongo-password', 'operator-reader-redis-password', 'operator-mongo-ui-password', 'operator-redis-insight-password',
    'operator-redis-insight-encryption-key', 'operator-rabbitmq-password', 'operator-keycloak-password', 'operator-keycloak-totp-base32',
    'operator-dashboard-token'
$required += $operatorParameters
# The automation's own Keycloak master-realm client procure-automation (plan 08b Task 4 fix round 1; procure-ai keycloakConfig.automationClient):
# the keycloak-config Job and kcadm sign in with it instead of the bootstrap admin's password. Generated in both stores.
$automationParameters = @('keycloak-automation-client-secret')
$required += $automationParameters
# The Keycloak gate of Argo CD's public host (plan 08c Task 1): hosted only (the local cluster has no gate).
if ($hosted) { $required += 'argocd-gate-cookie-secret' }

function New-RandomText([int] $length) {
    [Security.Cryptography.RandomNumberGenerator]::GetString([char[]] 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789', $length)
}
function New-TotpSecret {
    # 20 letters and digits, Base32-encoded (32 characters, no padding): what an authenticator app takes, and what Keycloak's OTP credential
    # holds as text after decoding (procure-ai deploy/charts/procure-platform/files/keycloak-operator-user.sh); pgAdmin keeps the Base32 form.
    $bytes = [Text.Encoding]::ASCII.GetBytes((New-RandomText 20))
    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'
    $bits = ($bytes | ForEach-Object { [Convert]::ToString($_, 2).PadLeft(8, '0') }) -join ''
    -join (0..($bits.Length / 5 - 1) | ForEach-Object { $alphabet[[Convert]::ToInt32($bits.Substring($_ * 5, 5), 2)] })
}
function Test-Missing([string] $name) { -not $secrets.ContainsKey("Parameters:$name") -or [string]::IsNullOrEmpty($secrets["Parameters:$name"]) }

# Generated once, stored in the user secrets first (stdin JSON merges into the store, no value on a command line). Local: only the values
# new in plan 07 and 08; the AppHost generates the same names on its first run (persisted parameters), whichever runs first, both then
# share the value. Hosted: every value (the store is this script's alone), plus the user name the hosted RabbitMQ uses.
$generated = [ordered]@{}
$toGenerate = if ($hosted) { $required } else { @('keycloak-db-password', 'keycloak-dashboard-secret', 'debezium-mongo-password') + $databasePasswords + $operatorParameters + $automationParameters }
foreach ($name in $toGenerate) {
    if (-not (Test-Missing $name)) { continue }
    switch ($name) {
        'admin-api-key' { $generated["Parameters:$name"] = New-RandomText 64 }
        'admin-api-key-sha256' { }  # derived from the key below
        'mongo-keyfile-content' { $generated["Parameters:$name"] = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(48)) }
        { $_ -like '*-totp-base32' } { $generated["Parameters:$name"] = New-TotpSecret }
        default { $generated["Parameters:$name"] = New-RandomText 32 }
    }
}
if ($hosted) {
    # The services compare the SHA-256 (hex) of the admin API key: derived whenever the key is new or the hash is missing.
    $apiKey = if ($generated.Contains('Parameters:admin-api-key')) { $generated['Parameters:admin-api-key'] } else { $secrets['Parameters:admin-api-key'] }
    if ($generated.Contains('Parameters:admin-api-key') -or (Test-Missing 'admin-api-key-sha256')) {
        $generated['Parameters:admin-api-key-sha256'] = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($apiKey))).ToLowerInvariant()
    }
    # RabbitMQ's default user `guest` may log in from localhost only; the hosted cluster gets its own user name.
    if (Test-Missing 'rabbitmq-username') { $generated['Parameters:rabbitmq-username'] = 'procure' }
}
if ($generated.Count -gt 0) {
    $generated | ConvertTo-Json -Compress | & dotnet user-secrets set --id $UserSecretsId | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'dotnet user-secrets set failed.' }
    Write-Host "Generated and stored in the $($storeName): $($generated.Keys -join ', ')"
    $secrets = Read-UserSecrets
}

function Get-Parameter([string] $name, $default = $null) {
    $value = $secrets["Parameters:$name"]
    if ([string]::IsNullOrEmpty($value)) {
        if ($null -ne $default) { return $default }
        throw "User secret Parameters:$name is missing in the $storeName. Run the AppHost once (it generates most values) or set it with 'dotnet user-secrets set --id $UserSecretsId Parameters:$name <value>'."
    }
    $value
}

$missing = @($required | Where-Object { [string]::IsNullOrEmpty($secrets["Parameters:$_"]) })
if ($missing) { throw "$storeName missing: $(($missing | ForEach-Object { "Parameters:$_" }) -join ', '). Run the AppHost once, then this script again." }

# The copy in DEMO PASSWORDS.txt (Dale's rule 2026-11-07: every generated secret has its value there, and the copy follows every
# regeneration; plan 08 final review B M4): every value of the store, written into its section on every run (the file is rewritten only
# when a value differs or is new). Hosted: "procure-ai hosted (Contabo) secrets", labels without the Parameters: prefix; local: "procure-ai
# local: all AppHost user secrets", labels as the store's keys. Prints only how many entries changed.
$demoEntries = [ordered]@{}
if ($hosted) {
    $demoSection = 'procure-ai hosted (Contabo) secrets'
    foreach ($key in $secrets.Keys | Where-Object { $_ -like 'Parameters:*' } | Sort-Object) { $demoEntries[$key.Substring('Parameters:'.Length)] = $secrets[$key] }
} else {
    $demoSection = 'procure-ai local: all AppHost user secrets'
    # Aspire's own bookkeeping (Aspire:VersionCheck:*) is not a secret.
    foreach ($key in $secrets.Keys | Where-Object { $_ -like 'Parameters:*' -or $_ -like 'AppHost:*' } | Sort-Object) { $demoEntries[$key] = $secrets[$key] }
}
$demoChanged = Sync-DemoPasswordSection -Section $demoSection -Entries $demoEntries
Write-Host "DEMO PASSWORDS.txt, section '$demoSection': $demoChanged of $($demoEntries.Count) entries added or updated (values not shown)."

# User names: the AppHost sets none, so Aspire's defaults apply (an override in the user secrets wins, as in the AppHost).
$rabbitUser = Get-Parameter 'rabbitmq-username' 'guest'
$mongoUser = Get-Parameter 'mongo-username' 'admin'
# Not a secret: the AppHost's appsettings.json sets Parameters:keycloak-admin to this.
$keycloakAdmin = Get-Parameter 'keycloak-admin' 'keycloak-admin'

$postgresPassword = Get-Parameter 'postgres-password'
$rabbitPassword = Get-Parameter 'rabbitmq-password'
$redisPassword = Get-Parameter 'redis-password'
$mongoPassword = Get-Parameter 'mongo-password'
$auditLogReaderPassword = Get-Parameter 'audit-log-reader-password'

$results = [System.Collections.Generic.List[string]]::new()
function Get-LiveSecretData([string] $namespace, [string] $name) {
    # The live Secret's data (key -> base64 value; never printed), empty for a missing Secret. Only stdout is parsed: a kubectl warning on
    # stderr (deprecation, version skew) goes to a temporary file and is shown only when kubectl fails.
    $errFile = New-TemporaryFile
    try {
        $json = & kubectl @KubectlArgs -n $namespace get secret $name -o json --ignore-not-found 2>$errFile
        if ($LASTEXITCODE -ne 0) { throw "kubectl get secret $namespace/$name failed: $((Get-Content -Raw $errFile).Trim())" }
    } finally {
        Remove-Item $errFile -ErrorAction SilentlyContinue
    }
    $data = [ordered]@{}
    if (-not "$json".Trim()) { return $data }
    $live = ($json | Out-String | ConvertFrom-Json -AsHashtable).data
    if ($live) { foreach ($key in @($live.Keys) | Sort-Object) { $data[$key] = $live[$key] } }
    $data
}
function Get-StaleKeys([string] $namespace, [string] $name, [System.Collections.IDictionary] $data) {
    # The live Secret's keys that $data does not have, with their values as they are (base64; never printed). Empty for a new Secret.
    $stale = [ordered]@{}
    $live = Get-LiveSecretData $namespace $name
    foreach ($key in $live.Keys) { if (-not $data.Contains($key)) { $stale[$key] = $live[$key] } }
    $stale
}
function Set-Secret([string] $namespace, [string] $name, [System.Collections.IDictionary] $data, [string] $type = 'Opaque') {
    # Server-side apply removes every key this field manager wrote before and leaves out now; without -Prune those keys are applied
    # again with their live values, so the Secret keeps them.
    $stale = Get-StaleKeys $namespace $name $data
    $keep = if ($Prune) { [ordered]@{} } else { $stale }
    $line = Invoke-Apply (New-SecretObject -Namespace $namespace -Name $name -Data $data -EncodedData $keep -Type $type)
    if ($stale.Count -gt 0 -and -not $Prune) {
        $line += "; stale key(s) kept (no longer written; remove with -Prune after the rollout): $($stale.Keys -join ', ')"
    } elseif ($stale.Count -gt 0) {
        # Server-side apply drops only the keys this field manager owned; a key another manager also owns (made by hand, an old
        # client-side apply) stays. Report what is really gone, read back from the cluster.
        $after = Get-LiveSecretData $namespace $name
        $removed = @($stale.Keys | Where-Object { -not $after.Contains($_) })
        $left = @($stale.Keys | Where-Object { $after.Contains($_) })
        if ($removed.Count -gt 0) { $line += "; stale key(s) pruned: $($removed -join ', ')" }
        if ($left.Count -gt 0) {
            $line += "; stale key(s) NOT removed (another field manager owns them; remove by hand with kubectl edit or patch): $($left -join ', ')"
        }
    }
    $results.Add($line)
}
function Set-ProcureSecret([string] $name, [System.Collections.IDictionary] $data, [string] $type = 'Opaque') {
    Set-Secret procure $name $data $type
}

Set-ProcureSecret procure-postgres ([ordered]@{ password = $postgresPassword })
Set-ProcureSecret procure-rabbitmq ([ordered]@{ username = $rabbitUser; password = $rabbitPassword; 'operator-password' = Get-Parameter 'operator-rabbitmq-password' })
Set-ProcureSecret procure-redis ([ordered]@{ password = $redisPassword; 'operator-reader-password' = Get-Parameter 'operator-reader-redis-password' })
Set-ProcureSecret procure-mongo ([ordered]@{ username = $mongoUser; password = $mongoPassword; keyfile = (Get-Parameter 'mongo-keyfile-content') })
Set-ProcureSecret procure-keycloak ([ordered]@{
    'admin-username'      = $keycloakAdmin
    'admin-password'      = Get-Parameter 'keycloak-admin-password'
    'demo-password'       = Get-Parameter 'keycloak-demo-password'
    'gateway-secret'      = Get-Parameter 'keycloak-gateway-secret'
    'internal-secret'     = Get-Parameter 'keycloak-internal-secret'
    'access-admin-secret' = Get-Parameter 'keycloak-access-admin-secret'
    'demo-login-secret'   = Get-Parameter 'keycloak-demo-login-secret'
    'dashboard-secret'    = Get-Parameter 'keycloak-dashboard-secret'
    'db-password'         = Get-Parameter 'keycloak-db-password'
    # Dale's own master-realm admin `operator` (plan 08b Task 4; the keycloak-config Job's operator-user container).
    'operator-password'    = Get-Parameter 'operator-keycloak-password'
    'operator-totp-base32' = Get-Parameter 'operator-keycloak-totp-base32'
    # The automation's master-realm client procure-automation (plan 08b Task 4 fix round 1): the keycloak-config Job and kcadm sign in with it.
    'automation-client-secret' = Get-Parameter 'keycloak-automation-client-secret'
})
# The Aspire dashboard (namespace observability) gets only its own client secret, not the other Keycloak values; the break-glass dashboard
# (plan 08b Task 4) the basic-auth login Traefik asks for in front of it (the entry keeps its first name, operator-dashboard-token).
Set-Secret observability procure-keycloak ([ordered]@{ 'dashboard-secret' = Get-Parameter 'keycloak-dashboard-secret' })
Set-Secret observability aspire-dashboard-direct-basic-auth ([ordered]@{
    'username' = 'operator'
    'password' = Get-Parameter 'operator-dashboard-token'
}) 'kubernetes.io/basic-auth'
# debezium-mongo's MongoDB user; the Postgres Debeziums each replicate as their database's own role (procure-db-roles).
Set-ProcureSecret procure-debezium ([ordered]@{ 'mongo-password' = Get-Parameter 'debezium-mongo-password' })
$dbRoles = [ordered]@{}
foreach ($service in $postgresServices + 'suppliers') { $dbRoles["$service-password"] = Get-Parameter "db-$service-password" }
foreach ($service in $capturedServices) { $dbRoles["$service-cdc-password"] = Get-Parameter "db-$service-cdc-password" }
$dbRoles['assistant-mongo-password'] = Get-Parameter 'db-assistant-mongo-password'
$dbRoles['audit-log-reader-password'] = $auditLogReaderPassword
$dbRoles['operator-reader-postgres-password'] = Get-Parameter 'operator-reader-postgres-password'
$dbRoles['operator-reader-mongo-password'] = Get-Parameter 'operator-reader-mongo-password'
Set-ProcureSecret procure-db-roles $dbRoles
Set-ProcureSecret procure-api-keys ([ordered]@{
    'admin-api-key'           = Get-Parameter 'admin-api-key'
    'admin-api-key-sha256'    = Get-Parameter 'admin-api-key-sha256'
    'simulator-api-key'       = Get-Parameter 'simulator-api-key'
    'supplier-webhook-secret' = Get-Parameter 'supplier-webhook-secret'
})

# --- The model provider's key (hosted only; the Fake provider needs none). Never stored in the user secrets: the env var is its one place. ---
if ($hosted) {
    $aiKey = [Environment]::GetEnvironmentVariable('AZURE_FOUNDRY_API_KEY', 'User') ?? $env:AZURE_FOUNDRY_API_KEY
    if ([string]::IsNullOrWhiteSpace($aiKey)) { throw 'The user env var AZURE_FOUNDRY_API_KEY (Azure Foundry key, DEMO PASSWORDS.txt) is not set.' }
    Set-ProcureSecret procure-ai-provider ([ordered]@{ 'api-key' = $aiKey.Trim() })
}

# --- Connection strings (controller ruling R2): the names the AppHost gives the apps (ConnectionStrings__<name>), in-cluster hosts. ---
function New-NpgsqlConnectionString([string] $user, [string] $password, [string] $database) {
    # DbConnectionStringBuilder quotes values the way Npgsql parses them (a password may hold ; or =).
    $builder = [System.Data.Common.DbConnectionStringBuilder]::new()
    $builder['Host'] = 'postgres'; $builder['Port'] = '5432'; $builder['Username'] = $user
    $builder['Password'] = $password; $builder['Database'] = $database
    $builder.ConnectionString
}
function New-MongoConnectionString([string] $user, [string] $password, [string] $database) {
    # Single-member replica set rs0 with TLS required (Task 3); directConnection as the AppHost's Debezium uses, so the member's
    # name in the replica set config does not matter. The pod trusts the local CA through SSL_CERT_DIR (procure-ca). The user lives in the
    # admin database (infra/mongo/users.js), hence authSource=admin.
    $user = [uri]::EscapeDataString($user); $password = [uri]::EscapeDataString($password)
    "mongodb://${user}:${password}@mongo:27017/${database}?authSource=admin&authMechanism=SCRAM-SHA-256&replicaSet=rs0&directConnection=true&tls=true"
}
if ($redisPassword -match '[,=]') { throw 'Parameters:redis-password holds , or =, which a StackExchange.Redis configuration string cannot carry.' }

$connectionStrings = [ordered]@{}
# Every service as its own role <service>_app (plan 08 ruling 6): the superuser's and root's passwords reach no app.
foreach ($service in $postgresServices) {
    $connectionStrings["${service}db"] = New-NpgsqlConnectionString "${service}_app" (Get-Parameter "db-$service-password") "${service}db"
}
$connectionStrings['suppliersdb'] = New-MongoConnectionString 'suppliers_app' (Get-Parameter 'db-suppliers-password') 'suppliersdb'
$connectionStrings['assistantchatdb'] = New-MongoConnectionString 'assistant_app' (Get-Parameter 'db-assistant-mongo-password') 'assistantchatdb'
$connectionStrings['rabbitmq'] = "amqp://$([uri]::EscapeDataString($rabbitUser)):$([uri]::EscapeDataString($rabbitPassword))@rabbitmq:5672"
$connectionStrings['redis'] = "redis:6379,password=$redisPassword"
# Audit reads the server's pgaudit log as audit_log_reader (ServiceResources.WithAuditLogReader, connection name "auditlog").
$connectionStrings['auditlog'] = New-NpgsqlConnectionString 'audit_log_reader' $auditLogReaderPassword 'auditdb'
Set-ProcureSecret procure-connection-strings $connectionStrings
# Older bootstraps also made a Secret procure-audit-log-reader that nothing reads (the password is in procure-connection-strings/auditlog);
# -Prune removes it so there is one place to rotate.
if ($Prune) {
    $stale = & kubectl @KubectlArgs -n procure delete secret procure-audit-log-reader --ignore-not-found 2>&1
    if ($LASTEXITCODE -ne 0) { throw "kubectl delete secret procure-audit-log-reader failed: $stale" }
    if ($stale) { $results.Add("$stale") }
}

# --- GHCR pull secret. Local (plan 07 ruling 7): the token in Dale's gh keyring. Hosted (plan 08 D4): the classic PAT with only
# read:packages in the user env var GHCR_READ_TOKEN, never the gh token (which can write to every repo). ---
if ($hosted) {
    $token = [Environment]::GetEnvironmentVariable('GHCR_READ_TOKEN', 'User') ?? $env:GHCR_READ_TOKEN
    if ([string]::IsNullOrWhiteSpace($token)) { throw 'The user env var GHCR_READ_TOKEN (GHCR read-only PAT, DEMO PASSWORDS.txt) is not set.' }
} else {
    $gh = (Get-Command gh -ErrorAction SilentlyContinue)?.Source ?? 'C:\Program Files\GitHub CLI\gh.exe'
    $token = (& $gh auth token 2>$null | Select-Object -First 1)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) { throw "'gh auth token' returned no token; sign in with 'gh auth login' first." }
}
$token = $token.Trim()
$dockerConfig = [ordered]@{ auths = [ordered]@{ 'ghcr.io' = [ordered]@{
    username = $GhcrUser
    password = $token
    auth     = ConvertTo-Base64 "${GhcrUser}:$token"
} } } | ConvertTo-Json -Depth 5 -Compress
Set-ProcureSecret ghcr-pull ([ordered]@{ '.dockerconfigjson' = $dockerConfig }) 'kubernetes.io/dockerconfigjson'

# --- The operator's web UIs (namespace operator, procure-ai deploy/charts/procure-ops; plan 08b Task 4). ---
$results.Add((Invoke-Apply (New-NamespaceObject 'operator')))
Set-Secret operator operator-pgadmin ([ordered]@{
    'password'        = Get-Parameter 'operator-pgadmin-password'
    'totp-base32'     = Get-Parameter 'operator-pgadmin-totp-base32'
    'reader-password' = Get-Parameter 'operator-reader-postgres-password'
})
Set-Secret operator operator-mongo-ui ([ordered]@{
    'password'        = Get-Parameter 'operator-mongo-ui-password'
    'reader-password' = Get-Parameter 'operator-reader-mongo-password'
})
Set-Secret operator operator-redis-insight ([ordered]@{
    'reader-password' = Get-Parameter 'operator-reader-redis-password'
    'encryption-key'  = Get-Parameter 'operator-redis-insight-encryption-key'
})
# Traefik's basicAuth middleware reads a kubernetes.io/basic-auth Secret (user name and password as they are; it is their one place here).
Set-Secret operator operator-redis-insight-basic-auth ([ordered]@{
    'username' = 'operator'
    'password' = Get-Parameter 'operator-redis-insight-password'
}) 'kubernetes.io/basic-auth'

# --- The Keycloak gate of Argo CD's public host (hosted only; plan 08c Task 1, envs/hosted/argocd.yaml). ---
if ($hosted) {
    $results.Add((Invoke-Apply (New-NamespaceObject 'argocd')))
    Set-Secret argocd argocd-gate ([ordered]@{ 'cookie-secret' = Get-Parameter 'argocd-gate-cookie-secret' })
}

$results | ForEach-Object { Write-Host $_ }
Write-Host "Secrets in namespaces procure, observability, operator$(if ($hosted) { ' and argocd' }): $($results.Count) applied (names only shown)."
