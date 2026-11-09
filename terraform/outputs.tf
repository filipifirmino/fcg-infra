output "cluster_name" {
  value = module.eks.cluster_name
}

output "update_kubeconfig_command" {
  value = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
}

output "ecr_repository_urls" {
  value = { for name, repository in aws_ecr_repository.services : name => repository.repository_url }
}

output "github_actions_role_arn" {
  description = "Valor da variável AWS_ROLE_ARN nos repositórios do GitHub."
  value       = aws_iam_role.github_actions.arn
}

output "external_secrets_role_arn" {
  description = "Anotação eks.amazonaws.com/role-arn do ServiceAccount do External Secrets Operator."
  value       = module.external_secrets_irsa.iam_role_arn
}

output "secret_names" {
  value = [for secret in aws_secretsmanager_secret.app : secret.name]
}
