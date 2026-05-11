# Variables Reference

Full variable descriptions, types, defaults, and validation rules.
For per-environment values see `docs/configuration.md`.

---

## Top-Level Variables

| Variable | Type | Default | Description |
|---|---|---|---|
| `enable_module` | `bool` | `false` | Master toggle. `false` destroys all resources without removing config. |
| `enable_exec_command` | `bool` | `false` | Enable ECS Exec (SSM shell). Off by default. Enable for dev/staging. Adds `ssmmessages:*` to task role. |
| `environment` | `string` | required | Deployment environment: `development`, `staging`, `uat`, `production` |
| `aws_region` | `string` | `"us-east-1"` | AWS region for all resources |
| `aws_account_id` | `string` | required | 12-digit AWS account ID |
| `aws_cross_account_id` | `string` | `null` | Cross-account ID for Secrets Manager access |
| `ecs_cluster_prefix` | `string` | `"demo-cluster"` | Project/cluster name used in all resource names |
| `common_tags` | `map(string)` | `{}` | Tags applied to all taggable resources. Propagated to running tasks via `propagate_tags = "TASK_DEFINITION"` |
| `random_suffix` | `string` | `""` | Hex suffix for IAM role names. Use `random_id.this.hex` to prevent naming conflicts across module calls |
| `secret_path_prefix` | `string` | `null` | Scope same-account Secrets Manager + SSM IAM to this prefix. `null` = wildcard. Example: `"production/platform"` → `secret:production/platform/*` |
| `cross_account_secret_path_prefix` | `string` | `null` | Scope cross-account Secrets Manager IAM. `null` = wildcard. Only applies when `aws_cross_account_id` is set |

### Validation Rules

| Variable | Rule |
|---|---|
| `aws_account_id` | Must match `^[0-9]{12}$` |
| `aws_cross_account_id` | Must match `^[0-9]{12}$` or `null` |
| `configure_ecs_service.launch_type` | Must be `FARGATE`, `EC2`, or `EXTERNAL` |
| `configure_load_balancers[*].type` | Must be `alb` or `nlb` |
| `configure_load_balancers[*].listener_rule.routing_type` | Must be `simple` or `complex` |
| `configure_load_balancers[*].listener_rule.routing_method` | Must be `host_header`, `path_pattern`, or `mixed_route` |
| `configure_load_balancers[*].listener_rule.priority` | `1–50000` or `null` |
| `configure_alerts.email_endpoints` | Each must match email regex |
| `configure_alerts.sms_endpoints` | Each must match E.164 `^\+[1-9]\d{1,14}$` |
| `scaling_policies.*.cooldown` | >= 0 |
| `scaling_policies.*.scale_by` | != 0 |
| `scaling_policies.*.evaluation_periods` | > 0 |

---

## `ecs_task_definition`

```hcl
ecs_task_definition = {
  task_name = string   # kebab-case, becomes part of all resource names

  container_definitions = {
    container_image = string   # full ECR URI with tag
    container_port  = number   # port exposed by the container
    host_port       = number   # optional, defaults to container_port
    fargate_cpu     = number   # 256 | 512 | 1024 | 2048 | 4096
    fargate_memory  = number   # must match CPU combination table
    stop_timeout    = number   # seconds SIGTERM → SIGKILL. Default 30. Fargate max 120.

    configure_healthcheck = {
      enabled     = bool          # default false
      command     = list(string)  # e.g. ["CMD-SHELL", "curl -sf http://localhost:8000/health || exit 1"]
      interval    = number        # default 30s
      timeout     = number        # default 5s
      retries     = number        # default 3
      startPeriod = number        # grace period before checks count. JVM: 60-120s
    }

    configure_command = {
      enabled = bool          # default false
      command = list(string)  # overrides Docker CMD
    }

    configure_entrypoint = {
      enabled    = bool          # default false
      entrypoint = list(string)  # overrides Docker ENTRYPOINT
    }
  }

  configure_secrets = {
    enable_secrets = bool
    set_secrets = list(object({
      name      = string   # env var name inside container
      valueFrom = string   # Secrets Manager ARN or SSM Parameter ARN
    }))
  }

  configure_environment = {
    enable_environment = bool
    set_environment = list(object({
      name  = string
      value = string
    }))
  }

  configure_volume = {
    enable_efs = bool
    set_efs_volumes = list(object({
      name      = string
      host_path = string
      efs_volume_configuration = list(object({
        file_system_id = string
        authorization_config = list(object({
          access_point_id = string
          iam             = string   # "ENABLED" | "DISABLED"
        }))
      }))
    }))
    set_mount_points = list(object({
      sourceVolume  = string
      containerPath = string
    }))
  }

  configure_logs = {
    enable_fluentbit               = bool     # default false
    fluentbit_image                = string   # default "amazon/aws-for-fluent-bit:stable"
    kinesis_stream_name            = string   # target Kinesis stream
    log_index_prefix               = string   # OpenSearch index prefix. defaults to var.environment
    kinesis_cross_account_role_arn = string   # null = same-account. ARN = cross-account
    fluentbit_config_s3_arn        = string   # null = default config. ARN = custom S3 config
    set_fluentbit_secrets          = list(object({ name = string, valueFrom = string }))
  }
}
```

---

## `network_configuration`

```hcl
network_configuration = {
  vpc_id         = string         # required
  vpc_subnet_ids = list(string)   # private subnets recommended
  vpc_cidr       = string         # used for auto-created VPC ingress rule

  aditional_security_group_rules = {
    vpcpeer_ingress_rule = {
      peering_cidrs = list(string)   # CIDRs from peered VPCs
    }
    custom_ingress_rule = {
      create_rules = map(object({    # for_each — stable plan diffs
        from_port   = number
        to_port     = number
        protocol    = string
        cidr_blocks = list(string)
        description = string
      }))
    }
  }
}
```

---

## `configure_load_balancers`

List — zero (no LB), one, or multiple entries. Each creates one target group + listener rule + optional DNS.

```hcl
configure_load_balancers = list(object({
  name           = string   # unique key used in resource names and outputs map
  type           = string   # "alb" | "nlb"
  container_port = number   # which container port this LB routes to

  target_group = {
    target_type                   = string   # "ip" (required for Fargate awsvpc)
    protocol                      = string   # ALB: "HTTP"|"HTTPS"  NLB: "TCP"|"TLS"|"UDP"
    deregistration_delay          = number   # seconds to drain. Default 300.
    slow_start                    = number   # ALB only. Default 0.
    load_balancing_algorithm_type = string   # ALB only. "round_robin"|"least_outstanding_requests"
    health_check = {
      path                = string   # ALB only (null for NLB TCP)
      protocol            = string
      matcher             = string   # ALB only. e.g. "200" or "200-299"
      interval            = number
      timeout             = number
      healthy_threshold   = number   # NLB: must equal unhealthy_threshold
      unhealthy_threshold = number
    }
  }

  listener_rule = {
    enable_routing     = bool
    listener_arn       = string         # existing ALB/NLB listener ARN
    routing_type       = string         # "simple" | "complex"
    routing_method     = string         # "host_header" | "path_pattern" | "mixed_route"
    host_header_value  = list(string)   # ALB only — ignored for NLB
    path_pattern_value = string         # used with "path_pattern" or "mixed_route"
    priority           = number         # 1-50000 | null (random). Set explicitly for shared listeners.
  }

  dns = {
    enabled        = bool
    hosted_zone_id = string   # Route53 Hosted Zone ID
    lb_dns_name    = string   # LB DNS name output
    lb_zone_id     = string   # LB zone ID output
  }
}))
```

---

## `configure_ecs_service`

```hcl
configure_ecs_service = {
  ecs_cluster_id   = string
  ecs_cluster_name = string
  launch_type      = string   # "FARGATE" | "EC2" | "EXTERNAL". Ignored when capacity_provider_strategy set.

  capacity_provider_strategy = list(object({
    capacity_provider = string   # "FARGATE" | "FARGATE_SPOT" | EC2 ASG name
    weight            = number
    base              = number   # guaranteed minimum tasks on this provider
  }))

  task_compatibilities = list(string)   # ["FARGATE"] | ["EC2"] | ["FARGATE","EC2"]

  scaling_capacity = {
    desired_count = number
    min_capacity  = number
    max_capacity  = number
  }

  service_connect = {
    enabled        = bool
    namespace_name = string   # Cloud Map private DNS namespace
  }

  health_check_grace_period_seconds = number   # must be >= configure_healthcheck.startPeriod
}
```

---

## `scaling_policies`

```hcl
scaling_policies = {
  enabled = bool

  cpu = {
    scale_up_enabled   = bool
    scale_down_enabled = bool
    scale_up = {
      threshold          = number   # CPU% that triggers alarm
      evaluation_periods = number   # consecutive periods (use 2-3 for fast reaction)
      period             = number   # seconds per evaluation period
      cooldown           = number   # seconds before next scale-up
      lower_bound        = number   # step lower bound (usually 0)
      scale_by           = number   # tasks to add (positive)
    }
    scale_down = {
      threshold          = number
      evaluation_periods = number   # use 5+ to avoid flapping
      period             = number
      cooldown           = number   # use 300+ to avoid oscillation
      upper_bound        = number   # step upper bound (usually 0)
      scale_by           = number   # tasks to remove (negative)
    }
  }

  memory = { ... }   # same structure as cpu

  target_tracking = {
    enabled                     = bool
    metric                      = string   # "ECSServiceAverageCPUUtilization" | "ECSServiceAverageMemoryUtilization" | "ALBRequestCountPerTarget"
    target_value                = number   # AWS maintains this metric value
    scale_in_cooldown           = number   # default 300
    scale_out_cooldown          = number   # default 60
    disable_scale_in            = bool     # true = scale out only
    alb_target_group_arn_suffix = string   # required for ALBRequestCountPerTarget
  }

  scheduled_actions = list(object({
    name         = string
    min_capacity = number
    max_capacity = number
    desired      = number          # optional — forces immediate count
    schedule     = string          # one-time: "at(2026-12-31T23:59:00)"
    recurrence   = string          # cron: "cron(0 8 * * MON-FRI)"
    timezone     = string          # IANA timezone. Default "UTC"
  }))
}
```

---

## `configure_alerts`

```hcl
configure_alerts = {
  enabled            = bool
  topic_name         = string
  email_endpoints    = list(string)   # each must be valid email
  sms_endpoints      = list(string)   # each must be E.164 format (+1234567890)
  lambda_arns        = list(string)   # Lambda ARNs subscribed to SNS
  slack_webhook_url  = string         # HTTPS SNS subscription
  teams_webhook_url  = string
  custom_webhook_url = string

  enabled_alerts = {
    cpu_high    = bool
    cpu_low     = bool
    memory_high = bool
    memory_low  = bool
  }
}
```
