param(
    [string]$EnvFile = (Join-Path $PSScriptRoot "..\.env"),
    [string]$Namespace = "fcg"
)

$ErrorActionPreference = "Stop"

$vars = @{}
Get-Content $EnvFile | Where-Object { $_ -match '^\s*[A-Za-z_][A-Za-z0-9_]*=' } | ForEach-Object {
    $name, $value = $_ -split '=', 2
    $vars[$name.Trim()] = $value.Trim()
}

function Get-Required([string]$name) {
    if (-not $vars[$name]) { throw "Variável $name ausente em $EnvFile" }
    $vars[$name]
}

function Set-Secret([string]$name, [hashtable]$data) {
    $args = @("create", "secret", "generic", $name, "-n", $Namespace, "--dry-run=client", "-o", "yaml")
    foreach ($key in $data.Keys) { $args += "--from-literal=$key=$($data[$key])" }
    kubectl @args | kubectl apply -f -
}

$jwt = Get-Required "JWT_SECRET"
$postgres = Get-Required "POSTGRES_PASSWORD"
$rabbit = Get-Required "RABBITMQ_PASSWORD"
$grafana = Get-Required "GRAFANA_ADMIN_PASSWORD"

Set-Secret "fcg-shared-secret" @{
    "Jwt__SecretKey"        = $jwt
    "RabbitMq__Password"    = $rabbit
    "AWS_ACCESS_KEY_ID"     = $vars["AWS_ACCESS_KEY_ID"]
    "AWS_SECRET_ACCESS_KEY" = $vars["AWS_SECRET_ACCESS_KEY"]
    "AWS_REGION"            = $(if ($vars["AWS_REGION"]) { $vars["AWS_REGION"] } else { "us-east-1" })
}
Set-Secret "catalog-api-secret" @{ "ConnectionStrings__Postgres" = "Host=postgres;Port=5432;Database=fcg_catalog_db;Username=fcg;Password=$postgres" }
Set-Secret "users-api-secret" @{ "ConnectionStrings__Postgres" = "Host=postgres;Port=5432;Database=fcg_users_db;Username=fcg;Password=$postgres" }
Set-Secret "payments-worker-secret" @{ "ConnectionStrings__Postgres" = "Host=postgres;Port=5432;Database=fcg_payments_db;Username=fcg;Password=$postgres" }
Set-Secret "postgres-secret" @{ "POSTGRES_PASSWORD" = $postgres }
Set-Secret "rabbitmq-secret" @{ "RABBITMQ_DEFAULT_USER" = "guest"; "RABBITMQ_DEFAULT_PASS" = $rabbit }
Set-Secret "grafana-secret" @{ "GF_SECURITY_ADMIN_PASSWORD" = $grafana }
