#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${1:-$(dirname "$0")/../.env}"
NAMESPACE="${NAMESPACE:-fcg}"

set -a
source "$ENV_FILE"
set +a

: "${JWT_SECRET:?JWT_SECRET ausente em $ENV_FILE}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD ausente em $ENV_FILE}"
: "${RABBITMQ_PASSWORD:?RABBITMQ_PASSWORD ausente em $ENV_FILE}"
: "${GRAFANA_ADMIN_PASSWORD:?GRAFANA_ADMIN_PASSWORD ausente em $ENV_FILE}"

apply_secret() {
  local name="$1"; shift
  kubectl create secret generic "$name" -n "$NAMESPACE" "$@" --dry-run=client -o yaml | kubectl apply -f -
}

apply_secret fcg-shared-secret \
  --from-literal=Jwt__SecretKey="$JWT_SECRET" \
  --from-literal=RabbitMq__Password="$RABBITMQ_PASSWORD" \
  --from-literal=AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}" \
  --from-literal=AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}" \
  --from-literal=AWS_REGION="${AWS_REGION:-us-east-1}"

for entry in catalog-api-secret:fcg_catalog_db users-api-secret:fcg_users_db payments-worker-secret:fcg_payments_db; do
  apply_secret "${entry%%:*}" \
    --from-literal=ConnectionStrings__Postgres="Host=postgres;Port=5432;Database=${entry##*:};Username=fcg;Password=$POSTGRES_PASSWORD"
done

apply_secret postgres-secret --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD"
apply_secret rabbitmq-secret --from-literal=RABBITMQ_DEFAULT_USER=guest --from-literal=RABBITMQ_DEFAULT_PASS="$RABBITMQ_PASSWORD"
apply_secret grafana-secret --from-literal=GF_SECURITY_ADMIN_PASSWORD="$GRAFANA_ADMIN_PASSWORD"
