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
