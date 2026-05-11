## =============================================================================
## Example: Complete — all capacity providers enabled
## Demonstrates: Fargate + FARGATE_SPOT + EC2 + Container Insights + Namespace
## Prerequisites: VPC with private subnets
## =============================================================================

provider "aws" {
  region = var.aws_region
}

module "ecs_cluster" {
  source = "../../"

  enable_module = true
  environment   = var.environment
  cluster_name  = var.cluster_name

  tags = {
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  ## Container Insights
  monitoring_settings = [
    {
      name  = "containerInsights"
      value = "enabled"
    }
  ]

  ## All three capacity providers — services choose which to use
  capacity_providers = {
    ## Fargate — guaranteed on-demand, awsvpc only
    fargate = {
      enabled        = true
      default_base   = 1    # 1 task always on Fargate
      default_weight = 1
    }

    ## FARGATE_SPOT — 70% cheaper, tolerate interruption
    fargate_spot = {
      enabled        = true
      default_base   = 0
      default_weight = 3    # 3x more tasks on SPOT by default
    }

    ## EC2 — bridge mode, GPU, high-density, or awsvpc on EC2
    ec2 = {
      enabled                        = true
      instance_type                  = "m5.large"
      ami_id                         = null         # auto-resolve ECS-optimized AMI
      min_size                       = 1
      max_size                       = 10
      desired_capacity               = 2            # initial only — ECS owns this after first apply
      vpc_zone_identifier            = data.aws_subnets.private.ids
      managed_scaling_enabled        = true
      managed_scaling_target         = 80           # 20% headroom for fast task placement
      managed_draining_enabled       = true         # drain tasks before instance termination
      instance_warmup_period         = 300          # 5m before new instance capacity is counted
      minimum_scaling_step_size      = 1
      maximum_scaling_step_size      = 10
      default_base                   = 0
      default_weight                 = 0            # services opt-in to EC2 explicitly
    }
  }

  ## Service Connect namespace (Cloud Map)
  namespace_configuration = {
    enabled        = true
    create_new     = true
    namespace_name = "${var.environment}-services"
    vpc_id         = data.aws_vpc.main.id
  }
}

## Data sources
data "aws_vpc" "main" {
  tags = { Environment = var.environment }
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.main.id]
  }
  tags = { Tier = "private" }
}
