data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

# Apenas sub-redes públicas e sem NAT Gateway: reduz custo em um ambiente de demonstração.
# Os nós recebem IP público, mas o security group do cluster só admite tráfego do próprio cluster e do load balancer.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.21"

  name = "${var.project}-vpc"
  cidr = "10.0.0.0/16"

  azs            = local.azs
  public_subnets = [for index, _ in local.azs : cidrsubnet("10.0.0.0/16", 8, index)]

  enable_nat_gateway      = false
  map_public_ip_on_launch = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
}
