## =============================================================================
## Example: Minimal — Fargate only, no extras
## =============================================================================

provider "aws" {
  region = var.aws_region
}

variable "aws_region"   { type = string; default = "us-east-1" }
variable "environment"  { type = string; default = "staging" }
variable "cluster_name" { type = string; default = "platform" }

module "ecs_cluster" {
  source = "../../"

  enable_module = true
  environment   = var.environment
  cluster_name  = var.cluster_name
}

output "cluster_id"   { value = module.ecs_cluster.cluster_id }
output "cluster_name" { value = module.ecs_cluster.cluster_name }
