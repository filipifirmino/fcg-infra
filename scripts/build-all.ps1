# Builda as 4 imagens Docker locais dos microsservicos FCG, na tag que os
# manifests K8s esperam (imagePullPolicy: Never exige a imagem ja presente
# localmente antes do kubectl apply).
#
# Uso: .\fcg-infra\scripts\build-all.ps1
# Deve ser executado a partir da pasta que contem todos os repositorios
# (a mesma pasta raiz onde ficam fcg-users-api, fcg-catalog-api, etc.).

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Resolve-Path (Join-Path $scriptDir "..\..")

$services = @(
  "fcg-users-api",
  "fcg-catalog-api",
  "fcg-payments-api",
  "fcg-notifications-api"
)

Write-Host "Build a partir de: $rootDir"
Write-Host ""

foreach ($service in $services) {
  $context = Join-Path $rootDir $service
  if (-not (Test-Path $context)) {
    Write-Warning "pasta '$context' nao encontrada, pulando."
    continue
  }

  Write-Host "==> docker build -t ${service}:latest $context"
  docker build -t "${service}:latest" $context
  Write-Host ""
}

Write-Host "Imagens geradas:"
docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.CreatedSince}}\t{{.Size}}" | Select-String "^fcg-"
