# Multiple Load Balancers — Public ALB + Internal NLB

**Pattern:** Service exposing two ports — HTTP to end-users and TCP for internal use
**Use for:** Services needing separate public HTTP and internal TCP/gRPC endpoints on the same task
**Concepts:** `configure_load_balancers` list (two entries), two container ports, custom SG rule for secondary port, target tracking scaling, map outputs
**Adopt for:** gRPC + HTTP service, Prometheus metrics endpoint + public API, admin API + public API, service mesh sidecar, database proxy + management port

---

## What This Creates

- ECS Fargate task definition + service
- Two target groups: one ALB (HTTP/8080) + one NLB (TCP/9090)
- Two listener rules: ALB host-header + NLB TCP forward
- Two Route53 DNS records: public domain + internal domain
- Custom security group rule for secondary port (9090)
- IAM task role with `kinesis:PutRecord` (FireLens)
- Target tracking + step scaling
- SNS alerts

---

## Prerequisites

- ECS cluster deployed
- Public ALB with HTTPS listener (`module.public_alb`)
- Internal NLB with TCP listener on port 9090 (`module.internal_nlb`)
- Public hosted zone + private hosted zone
- ECR repository for service image

---

## Key Concepts

**Security group covers `host_port` (8080) automatically**
Module rule `i01` opens `host_port` (the primary container port) from VPC CIDR. The secondary port (9090) used by the NLB must be added explicitly via `custom_ingress_rule` — it is not covered automatically.

**NLB does not support routing conditions**
ALB listener rules support `host_header`, `path_pattern`, `query_string`, etc. NLB listener rules forward ALL traffic on the listener port — no conditions. Set `routing_type = "simple"` and `routing_method = "host_header"` for NLB entries (fields are required but ignored for NLB).

**NLB health check — TCP, not HTTP**
NLB health checks use TCP by default. No path or matcher. Set `protocol = "TCP"` in the NLB target group health check. `healthy_threshold` and `unhealthy_threshold` must be equal for NLB.

**Output access via map**
With multiple LBs, outputs are maps keyed by the LB `name`. Access individual ARNs and FQDNs using the key.

**Two ports, one container**
The application listens on both ports simultaneously. ECS task definition has one `container_port/host_port`. The second port is accessible via the security group rule and NLB target group — no extra port mapping needed in the task definition.

---

## Configuration

```hcl
module "multi_lb_alb_nlb" {
  source = "../../"  # path to ecs-fargate-module-v3

  enable_module       = true
  enable_exec_command = false   # true for dev/staging debugging
  environment        = var.environment
  aws_region         = var.aws_region
  aws_account_id     = var.aws_account_id
  ecs_cluster_prefix = var.project_name
  common_tags        = var.common_tags

  ## -----------------------------------------------------------------------
  ## Task Definition
  ## Two ports: 8080 (HTTP/REST) and 9090 (gRPC/metrics)
  ## host_port = primary port — SG rule i01 opens this from VPC CIDR
  ## Port 9090 requires a custom SG rule (see network_configuration below)
  ## -----------------------------------------------------------------------
  ecs_task_definition = {
    task_name = "data-api"

    container_definitions = {
      container_image = "${var.ecr_base_url}/data-api:${var.image_tag}"
      container_port  = 8080
      host_port       = 8080
      fargate_cpu     = 1024
      fargate_memory  = 2048

      configure_healthcheck = {
        enabled     = true
        command     = ["CMD-SHELL", "curl -sf http://localhost:8080/health || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 20
      }
    }

    configure_environment = {
      enable_environment = true
      set_environment = [
        { name = "ENVIRONMENT",     value = var.environment },
        { name = "SERVICE_NAME",    value = "data-api" },
        { name = "HTTP_PORT",       value = "8080" },
        { name = "GRPC_PORT",       value = "9090" },
        { name = "METRICS_ENABLED", value = "true" }
      ]
    }

    configure_secrets = {
      enable_secrets = true
      set_secrets = [
        { name = "DATABASE_URL", valueFrom = "arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:${var.environment}/data-api/db-url" }
      ]
    }

    configure_logs = {
      enable_fluentbit    = true
      fluentbit_image     = "amazon/aws-for-fluent-bit:stable"
      kinesis_stream_name = "${var.environment}-app-logs"
    }
  }

  ## -----------------------------------------------------------------------
  ## Networking
  ## SG rule i01 covers host_port (8080) automatically
  ## Port 9090 (NLB) must be explicitly opened via custom_ingress_rule
  ## -----------------------------------------------------------------------
  network_configuration = {
    vpc_id         = module.vpc.vpc_id
    vpc_subnet_ids = module.vpc.private_subnet_ids
    vpc_cidr       = module.vpc.vpc_cidr

    aditional_security_group_rules = {
      custom_ingress_rule = {
        create_rules = {
          allow_grpc_metrics = {
            from_port   = 9090
            to_port     = 9090
            protocol    = "tcp"
            cidr_blocks = [module.vpc.vpc_cidr]
            description = "gRPC and Prometheus metrics from VPC"
          }
        }
      }
    }
  }

  ## -----------------------------------------------------------------------
  ## Two load balancers — ALB (HTTP) + NLB (TCP)
  ## Each entry = independent target group + listener rule
  ## -----------------------------------------------------------------------
  configure_load_balancers = [

    ## Public HTTP API via ALB
    {
      name           = "public-alb"
      type           = "alb"
      container_port = 8080

      target_group = {
        protocol                      = "HTTP"
        deregistration_delay          = 30
        load_balancing_algorithm_type = "least_outstanding_requests"
        health_check = {
          path    = "/health"
          matcher = "200"
        }
      }

      listener_rule = {
        enable_routing    = true
        listener_arn      = module.public_alb.https_listener_arn
        routing_type      = "simple"
        routing_method    = "host_header"
        host_header_value = ["data.${var.domain_name}"]
      }

      dns = {
        enabled        = true
        hosted_zone_id = module.public_dns_zone.zone_id
        lb_dns_name    = module.public_alb.dns_name
        lb_zone_id     = module.public_alb.zone_id
      }
    },

    ## Internal gRPC / Metrics via NLB (TCP)
    ## NLB forwards all traffic on the listener port — no routing conditions
    ## Health check must use TCP (not HTTP) for NLB target groups
    {
      name           = "internal-nlb"
      type           = "nlb"
      container_port = 9090

      target_group = {
        protocol             = "TCP"
        deregistration_delay = 60
        health_check = {
          protocol            = "TCP"   # NLB: no path, no matcher
          interval            = 30
          timeout             = 10
          healthy_threshold   = 3       # must equal unhealthy_threshold for NLB
          unhealthy_threshold = 3
        }
      }

      listener_rule = {
        enable_routing    = true
        listener_arn      = module.internal_nlb.tcp_listener_arn
        routing_type      = "simple"
        routing_method    = "host_header"   # NLB ignores conditions — required field only
        host_header_value = []
      }

      dns = {
        enabled        = true
        hosted_zone_id = module.private_dns_zone.zone_id
        lb_dns_name    = module.internal_nlb.dns_name
        lb_zone_id     = module.internal_nlb.zone_id
      }
    }
  ]

  ## -----------------------------------------------------------------------
  ## ECS Service
  ## -----------------------------------------------------------------------
  configure_ecs_service = {
    ecs_cluster_id   = module.ecs_cluster.cluster_id
    ecs_cluster_name = module.ecs_cluster.cluster_name
    launch_type      = "FARGATE"

    scaling_capacity = {
      desired_count = 2
      min_capacity  = 2
      max_capacity  = 15
    }

    health_check_grace_period_seconds = 30
  }

  scaling_policies = {
    enabled = true

    cpu = {
      scale_up_enabled   = true
      scale_down_enabled = true
      scale_up   = { threshold = 70, evaluation_periods = 3, period = 60, cooldown = 60,  lower_bound = 0, scale_by = 2  }
      scale_down = { threshold = 20, evaluation_periods = 5, period = 60, cooldown = 300, upper_bound = 0, scale_by = -1 }
    }

    memory = {
      scale_up_enabled   = true
      scale_down_enabled = false
      scale_up   = { threshold = 80, evaluation_periods = 3, period = 60, cooldown = 60, lower_bound = 0, scale_by = 1 }
      scale_down = { threshold = 0,  evaluation_periods = 1, period = 60, cooldown = 60, upper_bound = 0, scale_by = 0 }
    }

    target_tracking = {
      enabled            = true
      metric             = "ECSServiceAverageCPUUtilization"
      target_value       = 60
      scale_in_cooldown  = 300
      scale_out_cooldown = 60
    }
  }

  configure_alerts = {
    enabled         = true
    topic_name      = "alerts"
    email_endpoints = [var.oncall_email]
    enabled_alerts  = { cpu_high = true, cpu_low = false, memory_high = true, memory_low = false }
  }
}

## -----------------------------------------------------------------------
## Outputs — map access by LB name key
## -----------------------------------------------------------------------
output "data_api_public_tg_arn" {
  value = module.multi_lb_alb_nlb.target_group_arns["public-alb"]
}

output "data_api_internal_nlb_tg_arn" {
  value = module.multi_lb_alb_nlb.target_group_arns["internal-nlb"]
}

output "data_api_public_fqdn" {
  value = module.multi_lb_alb_nlb.dns_record_fqdns["public-alb"]
}

output "data_api_internal_nlb_fqdn" {
  value = module.multi_lb_alb_nlb.dns_record_fqdns["internal-nlb"]
}
```

---

## Notes

- **Stop timeout:** Default 30s. For gRPC streams on the NLB port, set `stop_timeout = 120` — gRPC clients need time to detect connection close and reconnect.
- **IAM secret scope (optional):** Add `secret_path_prefix = "${var.environment}/${var.project_name}"` to restrict Secrets Manager access to that path. `null` (default) = wildcard.
- **NLB `healthy_threshold` must equal `unhealthy_threshold`:** AWS NLB requirement. Setting them to different values causes a validation error on apply.
- **ALB on 8080 only:** ALB health check uses HTTP path `/health`. NLB health check uses TCP on 9090 — `path` and `matcher` are automatically set to `null` for NLB TCP health checks by the module.
- **NLB conditions not created:** The module gates all `host_header` and `path_pattern` condition blocks on `type == "alb"`. For NLB entries, zero condition blocks are sent to AWS — NLB does not support routing conditions and would reject them with an API error.
- **`routing_method` on NLB entry:** Required by variable schema but has no effect — conditions are not created for NLB. Set `routing_method = "host_header"` as a placeholder.
- **Priority field:** Set `priority` explicitly when multiple services share the same ALB listener to prevent `DuplicatePriority` collision. `null` (default) = random 100–900 (safe for single-service ALBs). NLB entries always use `priority = null` regardless of what is set.
  ```hcl
  # Two services sharing the same ALB listener — must use different explicit priorities
  listener_rule = { listener_arn = "...", priority = 100, ... }  # service A
  listener_rule = { listener_arn = "...", priority = 200, ... }  # service B
  ```
- **Related:** `docs/FEATURES_LIST.md#feature-1`, `docs/SECURITY_GROUP.md`
