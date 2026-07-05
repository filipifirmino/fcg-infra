#!/usr/bin/env bash
set -euo pipefail

# Builda as 4 imagens Docker locais dos microsserviços FCG, na tag que os
# manifests K8s esperam (imagePullPolicy: Never exige a imagem já presente
# localmente antes do kubectl apply).
#
# Uso: ./fcg-infra/scripts/build-all.sh
# Deve ser executado a partir da pasta que contém todos os repositórios
# (a mesma pasta raiz onde ficam fcg-users-api, fcg-catalog-api, etc.).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

SERVICES=(
  "fcg-users-api"
  "fcg-catalog-api"
  "fcg-payments-api"
  "fcg-notifications-api"
)

echo "Build a partir de: $ROOT_DIR"
echo

for service in "${SERVICES[@]}"; do
  context="$ROOT_DIR/$service"
  if [ ! -d "$context" ]; then
    echo "AVISO: pasta '$context' não encontrada, pulando." >&2
    continue
  fi

  echo "==> docker build -t ${service}:latest $context"
  docker build -t "${service}:latest" "$context"
  echo
done

echo "Imagens geradas:"
docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.CreatedSince}}\t{{.Size}}" | grep -E "^fcg-" || true
