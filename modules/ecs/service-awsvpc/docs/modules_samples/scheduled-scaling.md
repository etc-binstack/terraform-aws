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
