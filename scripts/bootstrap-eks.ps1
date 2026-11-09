param(
    [string]$AwsProfile = "fcg",
    [string]$Region = "us-east-1"
)

$ErrorActionPreference = "Stop"
$root = Join-Path $PSScriptRoot ".."

$cluster = terraform -chdir="$root/terraform" output -raw cluster_name
$esoRole = terraform -chdir="$root/terraform" output -raw external_secrets_role_arn

aws eks update-kubeconfig --name $cluster --region $Region --profile $AwsProfile

kubectl apply -f "$root/k8s/00-namespace.yaml"

helm repo add external-secrets https://charts.external-secrets.io
helm upgrade --install external-secrets external-secrets/external-secrets `
    --namespace external-secrets --create-namespace `
    --set installCRDs=true `
    --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$esoRole" `
    --wait

kubectl apply -f "$root/k8s/external-secrets/secret-store.yaml"
kubectl apply -f "$root/k8s/external-secrets/external-secrets.yaml"

kubectl apply -f "$root/k8s/shared/configmap.yaml"

foreach ($dir in "infra", "redis", "kong", "prometheus", "grafana") {
    kubectl apply -f "$root/k8s/$dir"
}
