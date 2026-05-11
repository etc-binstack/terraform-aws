## =============================================================================
## Example: Complete — all major features enabled
## Demonstrates: ALB + DNS, FireLens logging, autoscaling, alerts, EFS, secrets
## Prerequisites: VPC, ECS cluster, ALB, Route53 zone, Kinesis stream
## =============================================================================

provider "aws" {
  region = var.aws_region
}

module "api_service" {
  source = "../../"

  enable_module       = true
  enable_exec_command = true   # enable for staging/debug, false for prod
  environment         = var.environment
  aws_region          = var.aws_region
  aws_account_id      = var.aws_account_id
  ecs_cluster_prefix  = var.project_name
  secret_path_prefix  = "${var.environment}/${var.project_name}"

  common_tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "terraform"
  }

  ## Task Definition
  ecs_task_definition = {
    task_name = "api"

    container_definitions = {
      container_image = "${var.ecr_base_url}/api:${var.image_tag}"
      container_port  = 8000
      host_port       = 8000
      fargate_cpu     = 512
      fargate_memory  = 1024
      stop_timeout    = 30

      configure_healthcheck = {
        enabled     = true
        command     = ["CMD-SHELL", "curl -sf http://localhost:8000/health || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 20
      }
    }

    configure_environment = {
      enable_environment = true
      set_environment = [
        { name = "ENVIRONMENT", value = var.environment },
        { name = "LOG_LEVEL",   value = "INFO" },
        { name = "DB_HOST",     value = var.db_host }
      ]
    }

    configure_secrets = {
      enable_secrets = true
      set_secrets = [
        {
          name      = "DB_PASSWORD"
          valueFrom = "arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:${var.environment}/${var.project_name}/db-password"
        }
      ]
    }

    configure_logs = {
      enable_fluentbit    = true
      fluentbit_image     = "amazon/aws-for-fluent-bit:stable"
      kinesis_stream_name = "${var.environment}-app-logs"
      log_index_prefix    = "${var.project_name}-${var.environment}"
    }
  }

  ## Networking
  network_configuration = {
    vpc_id         = data.aws_vpc.main.id
    vpc_subnet_ids = data.aws_subnets.private.ids
    vpc_cidr       = data.aws_vpc.main.cidr_block
  }

  ## Load Balancer
  configure_load_balancers = [
    {
      name           = "public-alb"
      type           = "alb"
      container_port = 8000

      target_group = {
        protocol             = "HTTP"
        deregistration_delay = 30
        health_check         = { path = "/health", matcher = "200" }
      }

      listener_rule = {
        enable_routing    = true
        listener_arn      = data.aws_lb_listener.https.arn
        routing_type      = "simple"
        routing_method    = "host_header"
        host_header_value = ["api.${var.domain_name}"]
      }

      dns = {
        enabled        = true
        hosted_zone_id = data.aws_route53_zone.main.zone_id
        lb_dns_name    = data.aws_lb.main.dns_name
        lb_zone_id     = data.aws_lb.main.zone_id
      }
    }
  ]

  ## ECS Service
  configure_ecs_service = {
    ecs_cluster_id   = data.aws_ecs_cluster.main.id
    ecs_cluster_name = data.aws_ecs_cluster.main.cluster_name
    launch_type      = "FARGATE"
    scaling_capacity = {
      desired_count = 2
      min_capacity  = 1
      max_capacity  = 10
    }
    health_check_grace_period_seconds = 30
  }

  ## Autoscaling
  scaling_policies = {
    enabled = true
    cpu = {
      scale_up_enabled   = true
      scale_down_enabled = true
      scale_up   = { threshold = 70, evaluation_periods = 3, period = 60, cooldown = 60,  lower_bound = 0, scale_by = 1  }
      scale_down = { threshold = 20, evaluation_periods = 5, period = 60, cooldown = 300, upper_bound = 0, scale_by = -1 }
    }
    memory = {
      scale_up_enabled   = true
      scale_down_enabled = false
      scale_up   = { threshold = 80, evaluation_periods = 3, period = 60, cooldown = 60, lower_bound = 0, scale_by = 1 }
      scale_down = { threshold = 0,  evaluation_periods = 1, period = 60, cooldown = 60, upper_bound = 0, scale_by = 0 }
    }
  }

  ## Alerts
  configure_alerts = {
    enabled         = true
    topic_name      = "alerts"
    email_endpoints = [var.oncall_email]
    enabled_alerts  = { cpu_high = true, cpu_low = false, memory_high = true, memory_low = false }
  }
}

## Data sources — replace with your actual resource references
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

data "aws_ecs_cluster" "main" {
  cluster_name = "${var.environment}-${var.project_name}"
}

data "aws_lb" "main" {
  tags = { Environment = var.environment }
}

data "aws_lb_listener" "https" {
  load_balancer_arn = data.aws_lb.main.arn
  port              = 443
}

data "aws_route53_zone" "main" {
  name = var.domain_name
}
