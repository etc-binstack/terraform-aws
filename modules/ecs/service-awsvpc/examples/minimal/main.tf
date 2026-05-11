## =============================================================================
## Example: Minimal — simplest possible usage
## Demonstrates: Fargate task, no LB, no logging, basic autoscaling
## Use for: background workers, one-off jobs, internal services without ALB
## =============================================================================

provider "aws" {
  region = var.aws_region
}

variable "aws_region"     { type = string; default = "us-east-1" }
variable "aws_account_id" { type = string }
variable "ecr_base_url"   { type = string }

module "worker" {
  source = "../../"

  enable_module      = true
  environment        = "staging"
  aws_region         = var.aws_region
  aws_account_id     = var.aws_account_id
  ecs_cluster_prefix = "sample-app"

  ecs_task_definition = {
    task_name = "worker"
    container_definitions = {
      container_image = "${var.ecr_base_url}/worker:latest"
      container_port  = 8000
      fargate_cpu     = 256
      fargate_memory  = 512
    }
  }

  network_configuration = {
    vpc_id         = data.aws_vpc.main.id
    vpc_subnet_ids = data.aws_subnets.private.ids
    vpc_cidr       = data.aws_vpc.main.cidr_block
  }

  configure_load_balancers = []

  configure_ecs_service = {
    ecs_cluster_id   = data.aws_ecs_cluster.main.id
    ecs_cluster_name = data.aws_ecs_cluster.main.cluster_name
    launch_type      = "FARGATE"
    scaling_capacity = { desired_count = 1, min_capacity = 1, max_capacity = 5 }
  }

  scaling_policies = {
    enabled = false
    cpu    = { scale_up_enabled = false, scale_down_enabled = false, scale_up = { threshold = 0, evaluation_periods = 1, period = 60, cooldown = 60, lower_bound = 0, scale_by = 1 }, scale_down = { threshold = 0, evaluation_periods = 1, period = 60, cooldown = 60, upper_bound = 0, scale_by = -1 } }
    memory = { scale_up_enabled = false, scale_down_enabled = false, scale_up = { threshold = 0, evaluation_periods = 1, period = 60, cooldown = 60, lower_bound = 0, scale_by = 1 }, scale_down = { threshold = 0, evaluation_periods = 1, period = 60, cooldown = 60, upper_bound = 0, scale_by = -1 } }
  }

  configure_alerts = { enabled = false }
}

data "aws_vpc" "main" { tags = { Environment = "staging" } }
data "aws_subnets" "private" {
  filter { name = "vpc-id"; values = [data.aws_vpc.main.id] }
  tags = { Tier = "private" }
}
data "aws_ecs_cluster" "main" { cluster_name = "${var.environment}-${var.project_name}" }
