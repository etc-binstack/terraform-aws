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
