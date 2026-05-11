# Public ALB + Route53 DNS

**Pattern:** Public-facing HTTP/HTTPS service with domain routing
**Use for:** Any service exposed externally via a domain name on HTTPS
**Concepts:** ALB host-header routing, Route53 A alias, simple step scaling
**Adopt for:** Frontend SPA server, API gateway, reverse proxy, admin panel, marketing site backend

---

## What This Creates

- ECS Fargate task definition + service
- ALB target group with HTTP health check
- ALB listener rule (host-header match)
- Route53 A alias record → ALB (`dualstack.{alb-dns}`)
- IAM task + execution roles with Secrets Manager access
- Step scaling on CPU (up + down)
- SNS topic with email alerts

---

## Prerequisites

- ECS cluster deployed (`module.ecs_cluster`)
- Public ALB deployed with HTTPS listener (`module.public_alb`)
- Public Route53 hosted zone (`module.public_dns_zone`)
- ECR repository for the service image
- ACM certificate attached to the ALB listener (HTTPS termination at ALB)

---

## Key Concepts

**host_header routing (`routing_type = "simple"`)**
ALB forwards requests to this service only when the `Host` header matches `app.{domain_name}`. Multiple services can share the same ALB — each gets its own listener rule on a different host header.

**deregistration_delay = 30**
ALB waits 30 seconds before stopping health checks after a task is deregistered. Appropriate for stateless services with short request durations. Increase to 300+ for long-lived connections (file uploads, websockets).

**Route53 A alias**
`dualstack.{alb-dns}` enables both IPv4 and IPv6 routing. AWS alias records incur no DNS query charge and automatically track ALB IP changes.

---

## Configuration

```hcl
module "public_alb_dns" {
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
    task_name = "web-frontend"

    container_definitions = {
      container_image = "${var.ecr_base_url}/web-frontend:${var.image_tag}"
      container_port  = 3000
      host_port       = 3000
      fargate_cpu     = 512
      fargate_memory  = 1024

      configure_healthcheck = {
        enabled     = true
        command     = ["CMD-SHELL", "wget --quiet --tries=1 --spider http://localhost:3000/health || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 15
      }
    }

    configure_environment = {
      enable_environment = true
      set_environment = [
        { name = "ENVIRONMENT", value = var.environment },
        { name = "LOG_LEVEL",   value = "INFO" }
      ]
    }

    configure_secrets = {
      enable_secrets = true
      set_secrets = [
        {
          name      = "API_URL"
          valueFrom = "arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:${var.environment}/web-frontend/api-url"
        }
      ]
    }
  }

  ## -----------------------------------------------------------------------
  ## Networking
  ## -----------------------------------------------------------------------
  network_configuration = {
    vpc_id         = module.vpc.vpc_id
    vpc_subnet_ids = module.vpc.private_subnet_ids  # tasks in private subnets
    vpc_cidr       = module.vpc.vpc_cidr
  }

  ## -----------------------------------------------------------------------
  ## Load Balancer — public ALB, host-header routing, Route53 DNS
  ## -----------------------------------------------------------------------
  configure_load_balancers = [
    {
      name           = "public-alb"
      type           = "alb"
      container_port = 3000

      target_group = {
        protocol             = "HTTP"
        deregistration_delay = 30
        health_check = {
          path     = "/health"
          matcher  = "200"
          interval = 15
          timeout  = 5
        }
      }

      listener_rule = {
        enable_routing    = true
        listener_arn      = module.public_alb.https_listener_arn
        routing_type      = "simple"
        routing_method    = "host_header"
        host_header_value = ["app.${var.domain_name}"]
      }

      dns = {
        enabled        = true
        hosted_zone_id = module.public_dns_zone.zone_id
        lb_dns_name    = module.public_alb.dns_name
        lb_zone_id     = module.public_alb.zone_id
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
      min_capacity  = 1
      max_capacity  = 10
    }

    health_check_grace_period_seconds = 30
  }

  ## -----------------------------------------------------------------------
  ## Autoscaling — step scaling on CPU
  ## -----------------------------------------------------------------------
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

  ## -----------------------------------------------------------------------
  ## Alerts
  ## -----------------------------------------------------------------------
  configure_alerts = {
    enabled         = true
    topic_name      = "alerts"
    email_endpoints = [var.oncall_email]
    enabled_alerts  = { cpu_high = true, cpu_low = false, memory_high = true, memory_low = false }
  }
}
```

---

## Notes

- **Stop timeout:** Default 30s — sufficient for fast stateless frontends. Increase to `60` if the service handles long-running SSR or proxied requests.
- **IAM secret scope (optional):** Add `secret_path_prefix = "${var.environment}/${var.project_name}"` to restrict Secrets Manager + SSM access to that path only. `null` (default) = wildcard access.
- **HTTPS termination:** ALB handles TLS. Container receives plain HTTP on port 3000. No certificate needed inside the container.
- **Tasks in private subnets:** Even though the ALB is public, tasks stay in private subnets. ALB → private subnet → task. Never assign public IPs to Fargate tasks.
- **Multiple domains:** Add multiple values to `host_header_value` if the same service should respond on more than one domain.
- **Related:** `docs/FEATURES_LIST.md#feature-1`, `docs/SECURITY_GROUP.md`
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
# Background Worker on FARGATE_SPOT

**Pattern:** Async queue consumer with no inbound traffic, cost-optimised
**Use for:** Any service that consumes from a queue and tolerates interruption
**Concepts:** No load balancer, `FARGATE_SPOT` capacity provider, `configure_command` override, SIGTERM handling
**Adopt for:** Queue worker (SQS, RabbitMQ, Kafka consumer), event handler, email sender, image processor, report generator, data pipeline stage

---

## What This Creates

- ECS Fargate task definition + service (FARGATE_SPOT capacity provider)
- No load balancer, no target group, no listener rule
- IAM task role with `kinesis:PutRecord` (FireLens logging)
- IAM execution role with Secrets Manager access
- Step scaling on CPU
- SNS topic with email alerts

---

## Prerequisites

- ECS cluster deployed with `FARGATE_SPOT` capacity provider enabled
- Kinesis stream `{env}-app-logs` in same account
- ECR repository (same image as API service — command override differentiates roles)
- Queue or event source (SQS, RabbitMQ, etc.) already provisioned separately

---

## Key Concepts

**Same image, different role via `configure_command`**
One Docker image deployed as both API (no command override) and worker (command override). CI/CD builds one image, Terraform decides the startup command. No separate Dockerfile per role.

**FARGATE_SPOT — cost and interruption**
Up to 70% cheaper than on-demand Fargate. AWS can reclaim capacity with a 2-minute SIGTERM warning. App must handle SIGTERM: finish current job, stop polling, exit cleanly. Use `base = 0` — no guaranteed tasks.

**`capacity_provider_strategy` instead of `launch_type`**
These are mutually exclusive in AWS. When `capacity_provider_strategy` list is non-empty, `launch_type` must not be set. The module handles this automatically when `capacity_provider_strategy` is non-empty.

**SQS queue-depth scaling**
CPU-based scaling is a proxy for queue depth. For precise queue-depth scaling: create a CloudWatch alarm on `SQS ApproximateNumberOfMessages` and attach it to the same `aws_appautoscaling_target` outside this module.

**SIGTERM handling requirement**
```
AWS signals SIGTERM
  └── App must: finish current message, stop polling, flush logs, exit(0)
       └── 2 minutes max before SIGKILL
```
If app ignores SIGTERM → SIGKILL → in-flight message lost → must be re-queued or message becomes a dead letter.

---

## Configuration

```hcl
module "worker_spot" {
  source = "../../"  # path to ecs-fargate-module-v3

  enable_module       = true
  enable_exec_command = false   # true for dev/staging debugging
  environment        = var.environment
  aws_region         = var.aws_region
  aws_account_id     = var.aws_account_id
  ecs_cluster_prefix = var.project_name
  common_tags        = var.common_tags

  ## -----------------------------------------------------------------------
  ## Task Definition — same image as API, different command = different role
  ## -----------------------------------------------------------------------
  ecs_task_definition = {
    task_name = "notification-worker"

    container_definitions = {
      container_image = "${var.ecr_base_url}/notification-api:${var.image_tag}"
      container_port  = 8000   # required field — not used (no LB attached)
      fargate_cpu     = 1024
      fargate_memory  = 2048
      stop_timeout    = 120    # workers must finish current job — max Fargate limit

      ## Override Docker CMD — same image, different role
      ## Replace with your queue consumer entrypoint:
      ##   Celery:  ["celery", "-A", "app.worker", "worker", "--loglevel=info"]
      ##   Sidekiq: ["bundle", "exec", "sidekiq", "-C", "config/sidekiq.yml"]
      ##   BullMQ:  ["node", "dist/worker.js"]
      configure_command = {
        enabled = true
        command = ["celery", "-A", "app.worker", "worker", "--loglevel=info", "--concurrency=4", "-Q", "notifications"]
      }

      configure_healthcheck = {
        enabled     = true
        command     = ["CMD-SHELL", "celery -A app.worker inspect ping -d celery@$HOSTNAME || exit 1"]
        interval    = 60
        timeout     = 30
        retries     = 3
        startPeriod = 30
      }
    }

    configure_environment = {
      enable_environment = true
      set_environment = [
        { name = "ENVIRONMENT",        value = var.environment },
        { name = "SERVICE_NAME",       value = "notification-worker" },
        { name = "LOG_LEVEL",          value = "INFO" },
        { name = "WORKER_CONCURRENCY", value = "4" }
      ]
    }

    configure_secrets = {
      enable_secrets = true
      set_secrets = [
        { name = "DATABASE_URL",  valueFrom = "arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:${var.environment}/notification-api/db-url" },
        { name = "REDIS_URL",     valueFrom = "arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:${var.environment}/notification-api/redis-url" },
        { name = "SMTP_PASSWORD", valueFrom = "arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:${var.environment}/notification-api/smtp-password" }
      ]
    }

    configure_logs = {
      enable_fluentbit    = true
      fluentbit_image     = "amazon/aws-for-fluent-bit:stable"
      kinesis_stream_name = "${var.environment}-app-logs"
    }
  }

  ## -----------------------------------------------------------------------
  ## Networking — private subnets only, no ALB needed
  ## -----------------------------------------------------------------------
  network_configuration = {
    vpc_id         = module.vpc.vpc_id
    vpc_subnet_ids = module.vpc.private_subnet_ids
    vpc_cidr       = module.vpc.vpc_cidr
  }

  ## No load balancer — workers pull from queue, never receive inbound HTTP
  configure_load_balancers = []

  ## -----------------------------------------------------------------------
  ## ECS Service — FARGATE_SPOT (workers tolerate interruption)
  ## SIGTERM handler required — finish current job before exit
  ## -----------------------------------------------------------------------
  configure_ecs_service = {
    ecs_cluster_id   = module.ecs_cluster.cluster_id
    ecs_cluster_name = module.ecs_cluster.cluster_name

    capacity_provider_strategy = [
      { capacity_provider = "FARGATE_SPOT", weight = 1, base = 0 }
    ]
    task_compatibilities = ["FARGATE"]

    scaling_capacity = {
      desired_count = 2
      min_capacity  = 1
      max_capacity  = 20
    }
  }

  ## -----------------------------------------------------------------------
  ## Autoscaling — CPU-based (proxy for queue depth)
  ## For SQS queue-depth scaling: attach CW alarm on ApproximateNumberOfMessages
  ## to module.worker_spot's appautoscaling_target outside this module
  ## -----------------------------------------------------------------------
  scaling_policies = {
    enabled = true

    cpu = {
      scale_up_enabled   = true
      scale_down_enabled = true
      scale_up   = { threshold = 75, evaluation_periods = 3, period = 60, cooldown = 60,  lower_bound = 0, scale_by = 2  }
      scale_down = { threshold = 20, evaluation_periods = 5, period = 60, cooldown = 600, upper_bound = 0, scale_by = -1 }
    }

    memory = {
      scale_up_enabled   = true
      scale_down_enabled = false
      scale_up   = { threshold = 80, evaluation_periods = 3, period = 60, cooldown = 60, lower_bound = 0, scale_by = 1 }
      scale_down = { threshold = 0,  evaluation_periods = 1, period = 60, cooldown = 60, upper_bound = 0, scale_by = 0 }
    }
  }

  configure_alerts = {
    enabled         = true
    topic_name      = "alerts"
    email_endpoints = [var.oncall_email]
    enabled_alerts  = { cpu_high = true, cpu_low = false, memory_high = true, memory_low = false }
  }
}
```

---

## Notes

- **IAM secret scope (optional):** Add `secret_path_prefix = "${var.environment}/${var.project_name}"` to narrow Secrets Manager access. Workers often share an image with the API — use the same prefix so both can read from the same path.
- **FARGATE_SPOT cluster requirement:** The ECS cluster must have `FARGATE_SPOT` registered as a capacity provider. Without this, the service will fail to place tasks.
- **Mixed production pattern:** For critical workers that must always have capacity: use `base = 1` on `FARGATE` + `weight = 3` on `FARGATE_SPOT`. See `docs/FEATURES_LIST.md#feature-2`.
- **`container_port` required even with no LB:** The module requires the field. Set it to the app's default port even though no traffic arrives there.
- **Related:** `docs/ENTRYPOINT.md`, `docs/FEATURES_LIST.md#feature-2`, `docs/LOGS_CONFIG.md`
# Scheduled Scaling — Business Hours + Pre-event Warmup

**Pattern:** Service with predictable traffic that scales on a time-based schedule
**Use for:** Services with known peak/off-peak windows or one-time events
**Concepts:** `scheduled_actions` (cron + one-time `at()`), step scaling guardrails, timezone handling
**Adopt for:** Business-hours API, nightly batch processor, report generator, BI dashboard backend, pre-event warmup (product launch, campaign, flash sale)

---

## What This Creates

- ECS Fargate task definition + service
- Internal ALB target group + host-header listener rule
- Step scaling policies (CPU guardrails)
- Scheduled scaling actions: business-hours scale-up, off-peak scale-down, weekend minimal, one-time pre-event warmup
- SNS topic with email alerts

---

## Prerequisites

- ECS cluster deployed
- Internal ALB with HTTP listener
- Private hosted zone
- ECR repository for service image

---

## Key Concepts

**Scheduled actions override `min_capacity` and `max_capacity`**
The ECS service's `scaling_capacity` sets the baseline. Scheduled actions temporarily override `min_capacity` and `max_capacity` at the scheduled time. Step scaling still operates within the new bounds.

```
Baseline: min=1, max=20
Business hours action fires: min=4, max=20
  → autoscaler can now scale between 4 and 20
Off-peak action fires: min=1, max=4
  → autoscaler scales down to between 1 and 4
```

**Cron format**
AWS scheduled scaling uses `cron(minute hour day month day-of-week year)`:
- `cron(30 2 * * MON-FRI)` = 2:30 AM UTC every weekday
- Fields: Minute(0-59) Hour(0-23) Day(1-31) Month(1-12) Day-of-week(SUN-SAT) Year

**All times are UTC**
AWS Application Auto Scaling schedules run in UTC. Convert your local timezone before setting `recurrence`. IST (UTC+5:30): 8am IST = 02:30 UTC.

**One-time `at()` vs recurring `cron()`**
- `schedule = "at(2026-11-27T02:00:00)"` — fires once, remove after the event
- `recurrence = "cron(30 2 * * MON-FRI)"` — fires on a repeating schedule

**Pre-event warmup `desired` field**
When `desired` is set, the action also sets `desiredCount` directly — not just bounds. Use for pre-warming to a specific count before traffic arrives.

---

## Configuration

```hcl
module "scheduled_scaling" {
  source = "../../"  # path to ecs-fargate-module-v3

  enable_module       = true
  enable_exec_command = false   # true for dev/staging debugging
  environment        = var.environment
  aws_region         = var.aws_region
  aws_account_id     = var.aws_account_id
  ecs_cluster_prefix = var.project_name
  common_tags        = var.common_tags

  ecs_task_definition = {
    task_name = "report-api"

    container_definitions = {
      container_image = "${var.ecr_base_url}/report-api:${var.image_tag}"
      container_port  = 8080
      fargate_cpu     = 2048
      fargate_memory  = 4096

      configure_healthcheck = {
        enabled     = true
        command     = ["CMD-SHELL", "curl -sf http://localhost:8080/health || exit 1"]
        interval    = 30
        timeout     = 10
        retries     = 3
        startPeriod = 30
      }
    }

    configure_environment = {
      enable_environment = true
      set_environment = [
        { name = "ENVIRONMENT",  value = var.environment },
        { name = "SERVICE_NAME", value = "report-api" }
      ]
    }

    configure_secrets = {
      enable_secrets = true
      set_secrets = [
        { name = "DATABASE_URL", valueFrom = "arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:${var.environment}/report-api/db-url" }
      ]
    }
  }

  network_configuration = {
    vpc_id         = module.vpc.vpc_id
    vpc_subnet_ids = module.vpc.private_subnet_ids
    vpc_cidr       = module.vpc.vpc_cidr
  }

  configure_load_balancers = [
    {
      name           = "internal-alb"
      type           = "alb"
      container_port = 8080

      target_group = {
        protocol             = "HTTP"
        deregistration_delay = 60
        health_check         = { path = "/health", matcher = "200" }
      }

      listener_rule = {
        enable_routing    = true
        listener_arn      = module.internal_alb.http_listener_arn
        routing_type      = "simple"
        routing_method    = "host_header"
        host_header_value = ["reports.${var.internal_domain}"]
      }
    }
  ]

  configure_ecs_service = {
    ecs_cluster_id   = module.ecs_cluster.cluster_id
    ecs_cluster_name = module.ecs_cluster.cluster_name
    launch_type      = "FARGATE"

    ## Baseline — scheduled actions override min/max at their trigger time
    scaling_capacity = {
      desired_count = 1
      min_capacity  = 1
      max_capacity  = 20
    }
  }

  ## -----------------------------------------------------------------------
  ## Autoscaling — step scaling (guardrails) + scheduled actions (predictive)
  ## -----------------------------------------------------------------------
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

    ## Scheduled actions — all times UTC
    scheduled_actions = [

      ## Scale UP at business hours start (8am IST = 02:30 UTC)
      {
        name         = "business-hours-scale-up"
        min_capacity = 4
        max_capacity = 20
        recurrence   = "cron(30 2 * * MON-FRI)"
        timezone     = "UTC"
      },

      ## Scale DOWN at off-peak (10pm IST = 16:30 UTC)
      {
        name         = "off-peak-scale-down"
        min_capacity = 1
        max_capacity = 4
        recurrence   = "cron(30 16 * * MON-FRI)"
        timezone     = "UTC"
      },

      ## Minimal capacity on weekends
      {
        name         = "weekend-scale-down"
        min_capacity = 1
        max_capacity = 2
        recurrence   = "cron(0 0 * * SAT)"
        timezone     = "UTC"
      },

      ## One-time pre-event warmup — update date before each event, remove after
      {
        name         = "pre-event-warmup"
        min_capacity = 10
        max_capacity = 20
        desired      = 10
        schedule     = "at(2026-11-27T02:00:00)"   # 30 min before event start (UTC)
        timezone     = "UTC"
      }
    ]
  }

  configure_alerts = {
    enabled         = true
    topic_name      = "alerts"
    email_endpoints = [var.oncall_email]
    enabled_alerts  = { cpu_high = true, cpu_low = false, memory_high = true, memory_low = false }
  }
}
```

---

## Notes

- **Stop timeout:** Default 30s. For report generators running long queries, set `stop_timeout = 90` to allow the current report to finish before SIGKILL.
- **IAM secret scope (optional):** Add `secret_path_prefix = "${var.environment}/${var.project_name}"` to scope Secrets Manager access. `null` (default) = wildcard.
- **Remove pre-event warmup after the event:** The `at()` schedule fires once — leave it in and it does nothing after the event. But delete it before the next deploy to keep the config clean.
- **Cron day-of-week:** AWS uses `SUN-SAT` (not `0-6`). `MON-FRI` is valid. `SAT-SUN` is also valid.
- **Timezone field:** Accepts any IANA timezone string (`Asia/Kolkata`, `Europe/London`, `America/New_York`). Default is `UTC`.
- **Scaling action vs desired_count:** Scheduled actions only override `min_capacity`/`max_capacity`. The autoscaler then adjusts `desired_count` within those bounds. Setting `desired` forces an immediate count change.
- **Related:** `docs/FEATURES_LIST.md#feature-3`
# Stateful App with EFS Volume + Custom Command

**Pattern:** Containerised service needing persistent storage and/or a custom startup command
**Use for:** Services that store data beyond task lifetime OR require a startup mode switch per environment
**Concepts:** EFS IAM-authorized mount, `configure_command` env switch, `startPeriod` tuning, `health_check_grace_period_seconds` alignment
**Adopt for:** Auth servers, secret managers, observability backends, CMS platforms, self-hosted databases, ML inference servers, any JVM-based service with long startup time

---

## What This Creates

- ECS Fargate task definition with EFS volume + access point mount
- Custom startup command (env-conditional: dev mode vs prod mode)
- Internal ALB with HTTPS listener rule
- Private Route53 DNS record
- IAM policies for Secrets Manager access
- Conservative autoscaling (low scale-down thresholds to avoid churn)
- PagerDuty alerting via Lambda

---

## Prerequisites

- ECS cluster deployed
- EFS file system + access point provisioned (`var.efs_file_system_id`, `var.efs_access_point_id`)
- Task role must have `elasticfilesystem:ClientMount` + `elasticfilesystem:ClientWrite` on the EFS (add outside module)
- Internal ALB with HTTPS listener
- Private hosted zone
- Service image built with production-mode pre-build (for `["start", "--optimized"]` command)

---

## Key Concepts

**`configure_command` env-conditional**
Same Docker image runs in dev mode (`["start-dev"]`) or prod mode (`["start", "--optimized"]`) based on `var.environment`. No separate Docker images. No Dockerfile changes per environment. See `docs/ENTRYPOINT.md` for patterns.

**`startPeriod` — critical for JVM services**
JVM services (Java, Kotlin, Scala, Clojure) take 60–120 seconds to warm up before accepting traffic. If `startPeriod` is shorter than actual startup time, ECS marks the task unhealthy and kills it in a restart loop.

```
startPeriod = 90   → health check failures before 90s are ignored
                     after 90s: 3 consecutive failures → task unhealthy → replaced
```

**`health_check_grace_period_seconds` must match `startPeriod`**
ALB starts health checking immediately after task registers. If `health_check_grace_period_seconds < startPeriod`, ALB deregisters the task before it has time to start. Set both to the same value or `health_check_grace_period_seconds` slightly higher.

**EFS IAM authorization (`iam = "ENABLED"`)**
Uses the ECS task IAM role for EFS access — no static credentials. The access point restricts which path in the file system the task can mount. `transit_encryption = "ENABLED"` is set automatically by the module.

**Conservative autoscaling**
Stateful apps should not scale aggressively. Low `scale_by = 1`, high `cooldown = 600` on scale-down, memory scale-down disabled (JVM pinned heap). Avoids task churn that would cause EFS reconnection storms.

---

## Configuration

```hcl
module "stateful_app_efs" {
  source = "../../"  # path to ecs-fargate-module-v3

  enable_module       = true
  enable_exec_command = false   # true for dev/staging debugging
  environment        = var.environment
  aws_region         = var.aws_region
  aws_account_id     = var.aws_account_id
  ecs_cluster_prefix = var.project_name
  common_tags        = var.common_tags

  ## IAM secret scope (opt-in, recommended for production)
  ## Restricts Secrets Manager + SSM access to this path only
  ## null (default) = wildcard access to all secrets in account
  secret_path_prefix = "${var.environment}/${var.project_name}"  # → secret:production/platform/*

  ## -----------------------------------------------------------------------
  ## Task Definition
  ## -----------------------------------------------------------------------
  ecs_task_definition = {
    task_name = "stateful-app"

    container_definitions = {
      container_image = "${var.ecr_base_url}/stateful-app:${var.image_tag}"
      container_port  = 8080
      fargate_cpu     = 2048
      fargate_memory  = 4096
      stop_timeout    = 90     # JVM shutdown: wait for thread pool drain + connection close

      ## Dev mode vs prod mode — same image, command decides
      ## Prod mode requires pre-built optimized image (run kc.sh build first)
      configure_command = {
        enabled = true
        command = var.environment == "production" ? ["start", "--optimized"] : ["start-dev"]
      }

      ## startPeriod must cover full JVM cold-start time
      ## Increase to 120-180 for very heavy services
      configure_healthcheck = {
        enabled     = true
        command     = ["CMD-SHELL", "wget --quiet --tries=1 --spider http://localhost:8080/health/ready || exit 1"]
        interval    = 30
        timeout     = 10
        retries     = 3
        startPeriod = 90
      }
    }

    configure_environment = {
      enable_environment = true
      set_environment = [
        { name = "ENVIRONMENT",              value = var.environment },
        { name = "SERVICE_NAME",             value = "stateful-app" },
        { name = "DB_VENDOR",                value = "postgres" },
        { name = "DB_ADDR",                  value = var.db_host },
        { name = "DB_PORT",                  value = "5432" },
        { name = "DB_DATABASE",              value = var.db_name },
        { name = "PROXY_ADDRESS_FORWARDING", value = "true" },
        { name = "HTTP_ENABLED",             value = "true" },
        { name = "HEALTH_ENABLED",           value = "true" }
      ]
    }

    configure_secrets = {
      enable_secrets = true
      set_secrets = [
        { name = "DB_USER",        valueFrom = "arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:${var.environment}/stateful-app/db-user" },
        { name = "DB_PASSWORD",    valueFrom = "arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:${var.environment}/stateful-app/db-password" },
        { name = "ADMIN_PASSWORD", valueFrom = "arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:${var.environment}/stateful-app/admin-password" }
      ]
    }

    ## EFS volume — data persists across task restarts and replacements
    ## Task role needs: elasticfilesystem:ClientMount + ClientWrite (add outside module)
    configure_volume = {
      enable_efs = true
      set_efs_volumes = [
        {
          name      = "app-data"
          host_path = "/data"
          efs_volume_configuration = [
            {
              file_system_id = var.efs_file_system_id
              authorization_config = [
                {
                  access_point_id = var.efs_access_point_id
                  iam             = "ENABLED"
                }
              ]
            }
          ]
        }
      ]
      set_mount_points = [
        {
          sourceVolume  = "app-data"
          containerPath = "/opt/app/data"
        }
      ]
    }
  }

  ## -----------------------------------------------------------------------
  ## Networking — data subnets (most restricted, no internet route)
  ## -----------------------------------------------------------------------
  network_configuration = {
    vpc_id         = module.vpc.vpc_id
    vpc_subnet_ids = module.vpc.data_subnet_ids
    vpc_cidr       = module.vpc.vpc_cidr

    aditional_security_group_rules = {
      custom_ingress_rule = {
        create_rules = {
          allow_monitoring = {
            from_port   = 9990
            to_port     = 9990
            protocol    = "tcp"
            cidr_blocks = [module.vpc.monitoring_subnet_cidr]
            description = "Monitoring agent scrape"
          }
        }
      }
    }
  }

  ## -----------------------------------------------------------------------
  ## Load Balancer — internal ALB
  ## deregistration_delay = 120 for stateful session drain
  ## -----------------------------------------------------------------------
  configure_load_balancers = [
    {
      name           = "internal-alb"
      type           = "alb"
      container_port = 8080

      target_group = {
        protocol             = "HTTP"
        deregistration_delay = 120
        health_check = {
          path                = "/health/ready"
          matcher             = "200"
          interval            = 30
          timeout             = 10
          healthy_threshold   = 2
          unhealthy_threshold = 3
        }
      }

      listener_rule = {
        enable_routing    = true
        listener_arn      = module.internal_alb.https_listener_arn
        routing_type      = "simple"
        routing_method    = "host_header"
        host_header_value = ["auth.${var.internal_domain}"]
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
  ## health_check_grace_period_seconds must be >= configure_healthcheck.startPeriod
  ## -----------------------------------------------------------------------
  configure_ecs_service = {
    ecs_cluster_id   = module.ecs_cluster.cluster_id
    ecs_cluster_name = module.ecs_cluster.cluster_name
    launch_type      = "FARGATE"

    scaling_capacity = {
      desired_count = 2
      min_capacity  = 2   # never scale to 0 — stateful, EFS reconnect cost
      max_capacity  = 6
    }

    health_check_grace_period_seconds = 120  # must be >= startPeriod (90s above)
  }

  ## -----------------------------------------------------------------------
  ## Autoscaling — conservative: slow scale-up, very slow scale-down
  ## -----------------------------------------------------------------------
  scaling_policies = {
    enabled = true

    cpu = {
      scale_up_enabled   = true
      scale_down_enabled = true
      scale_up   = { threshold = 65, evaluation_periods = 2, period = 60, cooldown = 120, lower_bound = 0, scale_by = 1  }
      scale_down = { threshold = 15, evaluation_periods = 5, period = 60, cooldown = 600, upper_bound = 0, scale_by = -1 }
    }

    memory = {
      scale_up_enabled   = true
      scale_down_enabled = false   # JVM heap is pinned — memory never drops after warmup
      scale_up   = { threshold = 75, evaluation_periods = 2, period = 60, cooldown = 120, lower_bound = 0, scale_by = 1 }
      scale_down = { threshold = 0,  evaluation_periods = 1, period = 60, cooldown = 60,  upper_bound = 0, scale_by = 0 }
    }
  }

  configure_alerts = {
    enabled         = true
    topic_name      = "alerts"
    email_endpoints = [var.oncall_email]
    lambda_arns     = [module.pagerduty_notifier.lambda_arn]
    enabled_alerts  = { cpu_high = true, cpu_low = false, memory_high = true, memory_low = false }
  }
}
```

---

## Notes

- **IAM secret scope:** `secret_path_prefix` is set in this sample to `"{env}/{project}"`. All secrets must live under that path or task fails to start. Remove the variable (or set `null`) for wildcard access.
- **EFS IAM not in module:** The module does not create `elasticfilesystem:ClientMount/Write` permissions. Add these to the task role outside the module after calling it via `module.stateful_app_efs.task_role_arn`.
- **EFS throughput mode:** For write-heavy services, use `throughputMode = "provisioned"` (100+ MiB/s) on the EFS file system. Bursting mode throttles under load.
- **Multi-task EFS contention:** Multiple tasks mount the same EFS path. Ensure the application handles concurrent writes (use subdirectory per task, or a write-lock mechanism).
- **Production command pre-build:** `["start", "--optimized"]` requires the image to be pre-built with the optimized configuration embedded. Build the image with the optimization step before using this command.
- **Related:** `docs/ENTRYPOINT.md`, `docs/SECURITY_GROUP.md`
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
