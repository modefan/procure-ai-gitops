#Requires -Version 7.4
<#
.SYNOPSIS
    Creates the Kubernetes Secrets in namespaces `procure` and `observability` from the AppHost user secrets (the one source of every secret, plan 07 ruling 5).
.DESCRIPTION
    Reads `dotnet user-secrets` of the AppHost (UserSecretsId procure-ai-apphost). Values that are new in plan 07 or plan 08 and not there
    yet (keycloak-db-password, keycloak-dashboard-secret, debezium-mongo-password; the per-service database passwords db-<service>-password,
    db-<service>-cdc-password and db-assistant-mongo-password of plan 08 ruling 6) are generated once (32 letters and digits) and written to
    the user secrets first, so the AppHost and the cluster share them. Every Secret is applied with `kubectl apply`, so a second run
    reports "unchanged". Rerun this script after changing a user secret, then restart the pods that use it.
    Prints only object names, never values.

    Secrets (keys):
      procure-postgres           password
      procure-rabbitmq           username, password
      procure-redis              password
      procure-mongo              username, password, keyfile
      procure-keycloak           admin-username, admin-password, demo-password, gateway-secret, internal-secret, access-admin-secret,
                                 demo-login-secret, dashboard-secret, db-password
      procure-debezium           mongo-password (debezium-mongo's MongoDB user)
      procure-db-roles           <service>-password (accessdb ... requestsdb, suppliers on MongoDB), <service>-cdc-password (each Postgres
                                 database a Debezium reads), assistant-mongo-password, audit-log-reader-password: what the platform's
                                 db-roles Job sets on the roles and users, and what each Debezium replicates with
      procure-api-keys           admin-api-key, admin-api-key-sha256, simulator-api-key, supplier-webhook-secret
      procure-connection-strings one key per AppHost connection name (ConnectionStrings__<name>): the Postgres databases, suppliersdb,
                                 assistantchatdb, rabbitmq, redis, auditlog; in-cluster host names; MongoDB with tls=true. Each
                                 database as its service's own role or user (<service>_app), never the superuser or root
      ghcr-pull                  kubernetes.io/dockerconfigjson for ghcr.io from `gh auth token` (plan 07 ruling 7)
    In namespace observability (a pod reads Secrets of its own namespace only):
      procure-keycloak           dashboard-secret only (the Aspire dashboard's Keycloak client aspire-dashboard)
#>
[CmdletBinding()]
param(
    # The GitHub account whose token pulls the GHCR images.
    [string] $GhcrUser = 'modefan'
)

. (Join-Path $PSScriptRoot 'common.ps1')
Assert-ClusterReachable

$secrets = Read-UserSecrets

# The services' own database roles (plan 08 ruling 6; infra/postgres/roles.sql, infra/mongo/users.js): Postgres services, the ones a
# Debezium reads (a <service>_cdc role each), and the MongoDB-only service.
$postgresServices = 'access', 'approvals', 'assistant', 'audit', 'budgets', 'invoicing', 'purchasing', 'requests'
$capturedServices = 'access', 'approvals', 'assistant', 'budgets', 'invoicing', 'purchasing', 'requests'
$databasePasswords = @($postgresServices + 'suppliers' | ForEach-Object { "db-$_-password" }) +
    @($capturedServices | ForEach-Object { "db-$_-cdc-password" }) + 'db-assistant-mongo-password'

# New in plan 07 and 08: generated once, stored in the AppHost user secrets first (stdin JSON merges into the store, no value on a command
# line). The AppHost generates the same names on its first run (persisted parameters); whichever runs first, both then share the value.
$generated = [ordered]@{}
foreach ($name in @('keycloak-db-password', 'keycloak-dashboard-secret', 'debezium-mongo-password') + $databasePasswords) {
    if (-not $secrets.ContainsKey("Parameters:$name") -or [string]::IsNullOrEmpty($secrets["Parameters:$name"])) {
        $generated["Parameters:$name"] = [Security.Cryptography.RandomNumberGenerator]::GetString(
            [char[]] 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789', 32)
    }
}
if ($generated.Count -gt 0) {
    $generated | ConvertTo-Json -Compress | & dotnet user-secrets set --id $AppHostUserSecretsId | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'dotnet user-secrets set failed.' }
    Write-Host "Generated and stored in the AppHost user secrets: $($generated.Keys -join ', ')"
    $secrets = Read-UserSecrets
}

function Get-Parameter([string] $name, $default = $null) {
    $value = $secrets["Parameters:$name"]
    if ([string]::IsNullOrEmpty($value)) {
        if ($null -ne $default) { return $default }
        throw "AppHost user secret Parameters:$name is missing. Run the AppHost once (it generates most values) or set it with 'dotnet user-secrets set --id $AppHostUserSecretsId Parameters:$name <value>'."
    }
    $value
}

$required = 'postgres-password', 'rabbitmq-password', 'redis-password', 'mongo-password', 'mongo-keyfile-content',
    'keycloak-admin-password', 'keycloak-demo-password', 'keycloak-gateway-secret', 'keycloak-internal-secret',
    'keycloak-access-admin-secret', 'keycloak-demo-login-secret', 'keycloak-dashboard-secret', 'keycloak-db-password',
    'debezium-mongo-password', 'admin-api-key', 'admin-api-key-sha256', 'simulator-api-key',
    'supplier-webhook-secret', 'audit-log-reader-password'
$required += $databasePasswords
$missing = @($required | Where-Object { [string]::IsNullOrEmpty($secrets["Parameters:$_"]) })
if ($missing) { throw "AppHost user secrets missing: $(($missing | ForEach-Object { "Parameters:$_" }) -join ', '). Run the AppHost once, then this script again." }

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
function Set-ProcureSecret([string] $name, [System.Collections.IDictionary] $data, [string] $type = 'Opaque') {
    $results.Add((Invoke-Apply (New-SecretObject -Namespace procure -Name $name -Data $data -Type $type)))
}

Set-ProcureSecret procure-postgres ([ordered]@{ password = $postgresPassword })
Set-ProcureSecret procure-rabbitmq ([ordered]@{ username = $rabbitUser; password = $rabbitPassword })
Set-ProcureSecret procure-redis ([ordered]@{ password = $redisPassword })
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
})
# The Aspire dashboard (namespace observability) gets only its own client secret, not the other Keycloak values.
$results.Add((Invoke-Apply (New-SecretObject -Namespace observability -Name procure-keycloak -Data ([ordered]@{
    'dashboard-secret' = Get-Parameter 'keycloak-dashboard-secret'
}))))
# debezium-mongo's MongoDB user; the Postgres Debeziums each replicate as their database's own role (procure-db-roles).
Set-ProcureSecret procure-debezium ([ordered]@{ 'mongo-password' = Get-Parameter 'debezium-mongo-password' })
$dbRoles = [ordered]@{}
foreach ($service in $postgresServices + 'suppliers') { $dbRoles["$service-password"] = Get-Parameter "db-$service-password" }
foreach ($service in $capturedServices) { $dbRoles["$service-cdc-password"] = Get-Parameter "db-$service-cdc-password" }
$dbRoles['assistant-mongo-password'] = Get-Parameter 'db-assistant-mongo-password'
$dbRoles['audit-log-reader-password'] = $auditLogReaderPassword
Set-ProcureSecret procure-db-roles $dbRoles
Set-ProcureSecret procure-api-keys ([ordered]@{
    'admin-api-key'           = Get-Parameter 'admin-api-key'
    'admin-api-key-sha256'    = Get-Parameter 'admin-api-key-sha256'
    'simulator-api-key'       = Get-Parameter 'simulator-api-key'
    'supplier-webhook-secret' = Get-Parameter 'supplier-webhook-secret'
})

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
# remove it so there is one place to rotate.
$stale = & kubectl --context $KubeContext -n procure delete secret procure-audit-log-reader --ignore-not-found 2>&1
if ($LASTEXITCODE -ne 0) { throw "kubectl delete secret procure-audit-log-reader failed: $stale" }
if ($stale) { $results.Add("$stale") }

# --- GHCR pull secret (plan 07 ruling 7): the token in Dale's gh keyring; plan 08 replaces it with a read:packages-only token. ---
$gh = (Get-Command gh -ErrorAction SilentlyContinue)?.Source ?? 'C:\Program Files\GitHub CLI\gh.exe'
$token = (& $gh auth token 2>$null | Select-Object -First 1)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) { throw "'gh auth token' returned no token; sign in with 'gh auth login' first." }
$token = $token.Trim()
$dockerConfig = [ordered]@{ auths = [ordered]@{ 'ghcr.io' = [ordered]@{
    username = $GhcrUser
    password = $token
    auth     = ConvertTo-Base64 "${GhcrUser}:$token"
} } } | ConvertTo-Json -Depth 5 -Compress
Set-ProcureSecret ghcr-pull ([ordered]@{ '.dockerconfigjson' = $dockerConfig }) 'kubernetes.io/dockerconfigjson'

$results | ForEach-Object { Write-Host $_ }
Write-Host "Secrets in namespaces procure and observability: $($results.Count) applied (names only shown)."
