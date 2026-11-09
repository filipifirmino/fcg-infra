variable "region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type    = string
  default = "fcg"
}

variable "kubernetes_version" {
  type    = string
  default = "1.35"
}

variable "node_instance_type" {
  type    = string
  default = "t3.large"
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "ecr_repositories" {
  type    = list(string)
  default = ["fcg-users-api", "fcg-catalog-api", "fcg-payments-api"]
}

variable "reviews_table_name" {
  type    = string
  default = "fcg-game-reviews"
}

variable "secret_names" {
  description = "Segredos criados vazios no Secrets Manager; os valores são informados fora do Terraform."
  type        = list(string)
  default     = ["fcg/jwt", "fcg/postgres", "fcg/rabbitmq", "fcg/grafana", "fcg/aws-services"]
}

variable "github_owner" {
  type    = string
  default = "filipifirmino"
}

variable "github_repositories" {
  description = "Repositórios autorizados a assumir a role do pipeline a partir da branch main."
  type        = list(string)
  default     = ["fcg-users-api", "fcg-catalog-api"]
}

variable "create_github_oidc_provider" {
  description = "Desative se a conta já possuir o provider token.actions.githubusercontent.com."
  type        = bool
  default     = true
}
