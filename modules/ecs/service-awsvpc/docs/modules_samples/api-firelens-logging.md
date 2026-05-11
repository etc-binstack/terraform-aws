# API Service with FireLens Structured Logging

**Pattern:** Internal API with structured log pipeline
**Use for:** Any backend API that must emit structured logs to the observability platform
**Concepts:** FireLens sidecar, Kinesis stream routing, Secrets Manager, target tracking scaling, `mixed_route` listener rule
**Adopt for:** REST API, GraphQL API, gRPC service, internal microservice, backend-for-frontend

---

## What This Creates

- ECS Fargate task definition + service
- FireLens sidecar (Fluent Bit) — routes stdout logs to Kinesis
- Internal ALB target group + listener rule (`host_header AND path_pattern`)
- Private Route53 A alias record
- IAM task role with `kinesis:PutRecord` on `{env}-*` streams
- Step scaling (CPU guardrails) + Target tracking (smooth CPU-based autoscale)
- SNS topic with email + Slack Lambda subscription

---

## Prerequisites

- ECS cluster deployed (`module.ecs_cluster`)
- Internal ALB deployed with HTTPS listener (`module.internal_alb`)
- Private hosted zone (`module.private_dns_zone`)
- Kinesis stream `{env}-app-logs` created in same account
- ECR repository for the API image

---

## Key Concepts

**FireLens (enable_fluentbit = true)**
App container logs go to `awsfirelens` log driver — not CloudWatch. Fluent Bit sidecar collects stdout, enriches with ECS metadata, and writes to Kinesis. Task role gets `kinesis:PutRecord` automatically.

**log_index_prefix**
Sets the `ENVIRONMENT` env var inside Fluent Bit. Used as the OpenSearch index prefix. Pattern: `{project}-{env}` → produces index `myproject-production-2026.05.11`.

**mixed_route listener rule**
Routes only when BOTH host header matches `api.{domain}` AND path matches `/v1/*`. Use `routing_type = "simple"` + `routing_method = "host_header"` for simpler single-condition routing.

**Target tracking + step scaling together**
Both run in parallel. Target tracking smoothly scales to maintain 60% CPU. Step scaling acts as a fast emergency guardrail if CPU spikes past 85% before target tracking reacts.

---

## Configuration

```hcl
module "api_firelens_logging" {
  source = "../../"  # path to ecs-fargate-module-v3

  enable_module       = true
  enable_exec_command = false   # true for dev/staging debugging
  environment        = var.environment           # "development" | "staging" | "uat" | "production"
  aws_region         = var.aws_region
  aws_account_id     = var.aws_account_id
  ecs_cluster_prefix = var.project_name
  common_tags        = var.common_tags

  ## -----------------------------------------------------------------------
  ## Task Definition
  ## -----------------------------------------------------------------------
  ecs_task_definition = {
    task_name = "billing-api"

    container_definitions = {
      container_image = "${var.ecr_base_url}/billing-api:${var.image_tag}"
      container_port  = 8000
      host_port       = 8000
      fargate_cpu     = 1024
      fargate_memory  = 2048

      configure_healthcheck = {
        enabled     = true
        command     = ["CMD-SHELL", "curl -sf http://localhost:8000/health || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 20
      }
    }

    ## Non-sensitive config — visible in task definition JSON
    configure_environment = {
      enable_environment = true
      set_environment = [
        { name = "ENVIRONMENT",  value = var.environment },
        { name = "SERVICE_NAME", value = "billing-api" },
        { name = "LOG_LEVEL",    value = var.environment == "production" ? "INFO" : "DEBUG" },
        { name = "DB_HOST",      value = var.db_host }
      ]
    }

    ## Sensitive config — injected from Secrets Manager at task start, never plaintext
    configure_secrets = {
      enable_secrets = true
      set_secrets = [
        { name = "DATABASE_PASSWORD", valueFrom = "arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:${var.environment}/billing-api/db-password" },
        { name = "REDIS_URL",         valueFrom = "arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:${var.environment}/billing-api/redis-url" },
        { name = "JWT_SECRET",        valueFrom = "arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:${var.environment}/billing-api/jwt-secret" }
      ]
    }

    ## FireLens — stdout logs → Fluent Bit → Kinesis (same-account)
    ## kinesis:PutRecord added to task role automatically by module
    configure_logs = {
      enable_fluentbit    = true
      fluentbit_image     = "amazon/aws-for-fluent-bit:stable"
      kinesis_stream_name = "${var.environment}-app-logs"
      log_index_prefix    = "${var.project_name}-${var.environment}"
      set_fluentbit_secrets = []   # empty = IAM task role handles auth
    }
  }

  ## -----------------------------------------------------------------------
  ## Networking
  ## -----------------------------------------------------------------------
  network_configuration = {
    vpc_id         = module.vpc.vpc_id
    vpc_subnet_ids = module.vpc.private_subnet_ids
    vpc_cidr       = module.vpc.vpc_cidr
  }

  ## -----------------------------------------------------------------------
  ## Load Balancer — internal ALB (host + path, complex routing)
  ## -----------------------------------------------------------------------
  configure_load_balancers = [
    {
      name           = "internal-alb"
      type           = "alb"
      container_port = 8000

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
        enable_routing     = true
        listener_arn       = module.internal_alb.http_listener_arn
        routing_type       = "complex"
        routing_method     = "mixed_route"          # host_header AND path_pattern (AND logic)
        host_header_value  = ["api.${var.internal_domain}"]
        path_pattern_value = "/v1/*"
      }

      dns = {
        enabled        = true
        hosted_zone_id = module.private_dns_zone.zone_id
        lb_dns_name    = module.internal_alb.dns_name
        lb_zone_id     = module.internal_alb.zone_id
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
      max_capacity  = 20
    }

    health_check_grace_period_seconds = 30
  }

  ## -----------------------------------------------------------------------
  ## Autoscaling — target tracking (primary) + step scaling (guardrails)
  ## -----------------------------------------------------------------------
  scaling_policies = {
    enabled = true

    cpu = {
      scale_up_enabled   = true
      scale_down_enabled = true
      scale_up   = { threshold = 85, evaluation_periods = 3, period = 60, cooldown = 60,  lower_bound = 0, scale_by = 2  }
      scale_down = { threshold = 15, evaluation_periods = 5, period = 60, cooldown = 300, upper_bound = 0, scale_by = -1 }
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
      target_value       = 60     # AWS maintains ~60% average CPU across tasks
      scale_in_cooldown  = 300
      scale_out_cooldown = 60
      disable_scale_in   = false
    }
  }

  ## -----------------------------------------------------------------------
  ## Alerts
  ## -----------------------------------------------------------------------
  configure_alerts = {
    enabled         = true
    topic_name      = "alerts"
    email_endpoints = [var.oncall_email]
    lambda_arns     = [module.slack_notifier.lambda_arn]
    enabled_alerts  = { cpu_high = true, cpu_low = false, memory_high = true, memory_low = false }
  }
}
```

---

## Notes

- **Stop timeout:** Default 30s. For APIs with long requests (file uploads, reports), set `stop_timeout = 60` in `container_definitions` to allow in-flight requests to complete before SIGKILL.
- **IAM secret scope (optional):** Add `secret_path_prefix = "${var.environment}/${var.project_name}"` to restrict Secrets Manager access to that path only. Default (`null`) = wildcard. Set this in production to prevent the task role accessing other services' secrets.
- **Cross-account Kinesis:** Set `kinesis_cross_account_role_arn` to write logs to a central logs account. See `docs/LOGS_CONFIG.md`.
- **Custom Fluent Bit config:** Set `fluentbit_config_s3_arn` to enable PII filtering, multi-stream routing, JSON parsing.
- **`mixed_route` requires both fields:** `host_header_value` and `path_pattern_value` must both be set when `routing_method = "mixed_route"`.
- **`log_index_prefix`:** Renamed from `logstash_environment` — no Logstash dependency, controls OpenSearch index prefix only.
- **Related:** `docs/LOGS_CONFIG.md`, `docs/FEATURES_LIST.md#feature-3`
