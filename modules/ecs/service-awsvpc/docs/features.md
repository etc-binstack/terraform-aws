# Features List — ecs-fargate-module-v3

Six features added in this version. Feature 7 is planned for Phase 3 (not yet implemented). Feature 1 is a breaking change (replaces `configure_alb`/`configure_dns`). Features 2, 3, 4, 5 are fully backward-compatible.

---

## Table of Contents

- [Feature 1 — Multiple Load Balancers (ALB + NLB)](#feature-1--multiple-load-balancers-alb--nlb)
- [Feature 2 — EC2 + Fargate Capacity Provider Strategy](#feature-2--ec2--fargate-capacity-provider-strategy)
- [Feature 3 — Additional Scaling Policies](#feature-3--additional-scaling-policies)
- [Feature 4 — Deployment Circuit Breaker](#feature-4--deployment-circuit-breaker)
- [Feature 5 — ECS Exec (enable_execute_command)](#feature-5--ecs-exec-enable_execute_command)
- [Feature 6 — Container Stop Timeout (stop_timeout)](#feature-6--container-stop-timeout-stop_timeout)
- [Feature 7 — Shared Sub-Modules (Phase 3 — Planned)](#feature-7--shared-sub-modules-phase-3--planned)
- [Migration Guide — Feature 1](#migration-guide--feature-1)

---

## Feature 1 — Multiple Load Balancers (ALB + NLB)

### What It Does

Single module call can now attach **any number of load balancers** (ALB, NLB, or both) to one ECS service. Each LB entry creates its own target group, listener rule, and optional Route53 DNS record independently.

Replaces the old `configure_alb` + `configure_dns` pair with a single `configure_load_balancers` list. Zero entries = no LB (worker pattern). One entry = standard. Multiple entries = multi-port service.

### Variable

```hcl
configure_load_balancers = list(object({
  name           = string  # unique key — used in resource naming
  type           = string  # "alb" | "nlb"
  container_port = number  # which container port this LB routes to

  target_group = optional(object({
    target_type                   = optional(string, "ip")
    protocol                      = optional(string, "HTTP")
    deregistration_delay          = optional(number, 300)
    slow_start                    = optional(number, 0)
    load_balancing_algorithm_type = optional(string, "round_robin")
    health_check = optional(object({
      path                = optional(string, "/")
      protocol            = optional(string, "HTTP")
      matcher             = optional(string, "200")
      interval            = optional(number, 30)
      timeout             = optional(number, 5)
      healthy_threshold   = optional(number, 3)
      unhealthy_threshold = optional(number, 2)
    }), {})
  }), {})

  listener_rule = optional(object({
    enable_routing     = optional(bool, true)
    listener_arn       = string
    routing_type       = optional(string, "simple")      # "simple" | "complex"
    routing_method     = optional(string, "host_header") # "host_header" | "path_pattern" | "mixed_route"
    host_header_value  = optional(list(string), [])
    path_pattern_value = optional(string, "/*")
    # ALB only: explicit priority prevents DuplicatePriority when multiple services share
    # the same listener. null = random 100-900. NLB always uses null (ignored).
    priority           = optional(number, null)          # 1-50000 | null
  }), { listener_arn = "" })

  dns = optional(object({
    enabled        = optional(bool, false)
    hosted_zone_id = optional(string, "")
    lb_dns_name    = optional(string, "")
    lb_zone_id     = optional(string, "")
  }), {})
}))
```

### Outputs (map — keyed by name)

```hcl
module.svc.target_group_arns["public-alb"]    # string — TG ARN
module.svc.listener_rule_arns["public-alb"]   # string — listener rule ARN
module.svc.dns_record_fqdns["public-alb"]     # string — Route53 FQDN
```

---

### Example A — No Load Balancer (background worker)

```hcl
configure_load_balancers = []
```

No target group, no listener rule, no DNS record created.

---

### Example B — Single ALB (standard HTTP service)

```hcl
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
      listener_arn      = module.alb.https_listener_arn
      routing_type      = "simple"
      routing_method    = "host_header"
      host_header_value = ["api.example.com"]
    }

    dns = {
      enabled        = true
      hosted_zone_id = module.dns_zone.zone_id
      lb_dns_name    = module.alb.dns_name
      lb_zone_id     = module.alb.zone_id
    }
  }
]
```

---

### Example C — ALB (HTTP) + NLB (TCP/gRPC) on same service

Container exposes port 8080 (REST) and port 9090 (gRPC/metrics). Each LB routes to a different port on the same task.

> **Note:** Security group rule `i01` only covers `host_port`. Add a custom rule for port 9090 in `network_configuration.aditional_security_group_rules.custom_ingress_rule`.

```hcl
configure_load_balancers = [
  {
    name           = "public-alb"
    type           = "alb"
    container_port = 8080

    target_group = {
      protocol = "HTTP"
      load_balancing_algorithm_type = "least_outstanding_requests"
      health_check = { path = "/health", matcher = "200" }
    }

    listener_rule = {
      listener_arn      = module.public_alb.https_listener_arn
      routing_type      = "simple"
      routing_method    = "host_header"
      host_header_value = ["api.example.com"]
    }

    dns = {
      enabled        = true
      hosted_zone_id = module.public_zone.zone_id
      lb_dns_name    = module.public_alb.dns_name
      lb_zone_id     = module.public_alb.zone_id
    }
  },
  {
    name           = "internal-nlb"
    type           = "nlb"
    container_port = 9090

    target_group = {
      protocol = "TCP"
      health_check = {
        protocol            = "TCP"
        interval            = 30
        healthy_threshold   = 3
        unhealthy_threshold = 3
      }
    }

    listener_rule = {
      listener_arn   = module.internal_nlb.tcp_listener_arn
      routing_type   = "simple"
      routing_method = "host_header"  # required field — no conditions created for NLB (module gates on type=="alb")
    }
  }
]
```

---

### Example D — Complex routing (host + path conditions on same ALB)

```hcl
configure_load_balancers = [
  {
    name           = "api-v2"
    type           = "alb"
    container_port = 8000

    target_group = { protocol = "HTTP", health_check = { path = "/health" } }

    listener_rule = {
      listener_arn       = module.alb.https_listener_arn
      routing_type       = "complex"
      routing_method     = "mixed_route"     # host_header AND path_pattern (AND logic)
      host_header_value  = ["api.example.com"]
      path_pattern_value = "/v2/*"
    }
  }
]
```

---

---

## Feature 2 — EC2 + Fargate Capacity Provider Strategy

### What It Does

`configure_ecs_service` now supports `capacity_provider_strategy` — a list of providers with `weight` and `base` values. When set, it replaces `launch_type` on the ECS service (AWS requires these to be mutually exclusive).

Enables: `FARGATE_SPOT` (cost reduction), mixed FARGATE + FARGATE_SPOT (guaranteed base + cheap scale), EC2 launch type via ASG, or any combination of up to 6 providers.

Also adds `task_compatibilities` to control `requires_compatibilities` on the task definition — defaults to `["FARGATE"]`.

### Variable Addition (inside `configure_ecs_service`)

```hcl
configure_ecs_service = {
  ecs_cluster_id   = string
  ecs_cluster_name = string

  # Simple path — set one type, leave capacity_provider_strategy empty
  launch_type = optional(string, "FARGATE")  # "FARGATE" | "EC2" | "EXTERNAL"

  # Advanced path — when set, overrides launch_type (mutually exclusive in AWS)
  capacity_provider_strategy = optional(list(object({
    capacity_provider = string   # "FARGATE" | "FARGATE_SPOT" | EC2 ASG name
    weight            = number   # proportion of tasks (after base is satisfied)
    base              = optional(number, 0)  # guaranteed minimum tasks on this provider
  })), [])

  # Controls task definition requires_compatibilities
  # Default ["FARGATE"] — set ["EC2"] for EC2 launch, ["FARGATE","EC2"] for mixed
  task_compatibilities = optional(list(string), ["FARGATE"])

  scaling_capacity = object({ ... })
  ...
}
```

### How Weight + Base Work

```
Phase 1: Satisfy base (guaranteed minimum per provider, regardless of SPOT interruption)
Phase 2: Distribute remaining tasks by weight ratio

Example: FARGATE base=1 weight=1, FARGATE_SPOT base=0 weight=3

desired=1  → [1 FARGATE]               (base satisfied, nothing remaining)
desired=4  → [1 FARGATE] [3 SPOT]      (base + remaining split 1:3)
desired=8  → [2 FARGATE] [6 SPOT]      (base + 7 remaining: 25% FARGATE, 75% SPOT)
desired=12 → [3 FARGATE] [9 SPOT]      (base + 11 remaining: 25%/75%)
```

Weight is a proportion of remaining tasks — not a multiplier.

---

### Example A — Pure FARGATE (default, unchanged behaviour)

```hcl
configure_ecs_service = {
  ecs_cluster_id   = module.ecs_cluster.cluster_id
  ecs_cluster_name = module.ecs_cluster.cluster_name
  launch_type      = "FARGATE"           # capacity_provider_strategy = [] (default)
  scaling_capacity = { desired_count = 2, min_capacity = 1, max_capacity = 10 }
}
```

---

### Example B — Pure FARGATE_SPOT (background worker, 70% cheaper)

```hcl
configure_ecs_service = {
  ecs_cluster_id   = module.ecs_cluster.cluster_id
  ecs_cluster_name = module.ecs_cluster.cluster_name

  capacity_provider_strategy = [
    { capacity_provider = "FARGATE_SPOT", weight = 1, base = 0 }
  ]
  task_compatibilities = ["FARGATE"]

  scaling_capacity = { desired_count = 2, min_capacity = 1, max_capacity = 20 }
}
```

> FARGATE_SPOT can be interrupted with 2-minute SIGTERM warning. App must handle SIGTERM gracefully.

---

### Example C — Mixed: guaranteed base + SPOT scale (production cost optimisation)

```hcl
configure_ecs_service = {
  ecs_cluster_id   = module.ecs_cluster.cluster_id
  ecs_cluster_name = module.ecs_cluster.cluster_name

  capacity_provider_strategy = [
    { capacity_provider = "FARGATE",      weight = 1, base = 2 },  # always 2 on-demand tasks
    { capacity_provider = "FARGATE_SPOT", weight = 3, base = 0 }   # remaining scale on SPOT
  ]
  task_compatibilities = ["FARGATE"]

  scaling_capacity = { desired_count = 4, min_capacity = 2, max_capacity = 20 }
}
```

---

### Example D — EC2 launch type (stateful services needing instance store or high I/O)

```hcl
configure_ecs_service = {
  ecs_cluster_id   = module.ecs_cluster.cluster_id
  ecs_cluster_name = module.ecs_cluster.cluster_name
  launch_type      = "EC2"

  task_compatibilities = ["EC2"]    # task def requires_compatibilities = ["EC2"]

  scaling_capacity = { desired_count = 3, min_capacity = 3, max_capacity = 6 }
}
```

---

### When to Use Which

| Mode | `launch_type` | `capacity_provider_strategy` | Use When |
|---|---|---|---|
| Standard Fargate | `"FARGATE"` | `[]` | Production APIs, stateful services |
| FARGATE_SPOT only | not set | `[{FARGATE_SPOT, w=1, b=0}]` | Workers, batch — interruption tolerable |
| Mixed Fargate+SPOT | not set | `[{FARGATE,w=1,b=N}, {SPOT,w=3,b=0}]` | Production + cost savings |
| EC2 | `"EC2"` | `[]` | High I/O, instance store, stateful clusters |

---

---

## Feature 3 — Additional Scaling Policies

### What It Does

Two new optional scaling types added to `scaling_policies`, alongside the existing CPU and Memory step scaling:

1. **Target Tracking** — AWS automatically manages scale-up/down to maintain a target metric value. No thresholds or step bounds to configure.
2. **Scheduled Actions** — Override min/max/desired at specific times via cron or one-time `at()` schedule.

Both are additive — they run in parallel with existing step scaling policies.

### Variable Additions (inside `scaling_policies`)

```hcl
scaling_policies = {
  enabled = bool
  cpu     = object({ ... })  # existing step scaling
  memory  = object({ ... })  # existing step scaling

  ## NEW — Target Tracking
  target_tracking = optional(object({
    enabled      = optional(bool, false)
    metric       = optional(string, "ECSServiceAverageCPUUtilization")
    # metric options:
    #   "ECSServiceAverageCPUUtilization"    — keep CPU at target_value %
    #   "ECSServiceAverageMemoryUtilization" — keep Memory at target_value %
    #   "ALBRequestCountPerTarget"           — keep RPS per task at target_value
    target_value                = optional(number, 60)
    scale_in_cooldown           = optional(number, 300)
    scale_out_cooldown          = optional(number, 60)
    disable_scale_in            = optional(bool, false)
    alb_target_group_arn_suffix = optional(string, "")  # required for ALBRequestCountPerTarget
  }), { enabled = false })

  ## NEW — Scheduled Actions
  scheduled_actions = optional(list(object({
    name         = string
    min_capacity = optional(number)
    max_capacity = optional(number)
    desired      = optional(number)
    schedule     = optional(string)    # one-time:  "at(2026-12-31T23:59:00)"
    recurrence   = optional(string)    # recurring: "cron(0 8 * * MON-FRI)"
    timezone     = optional(string, "UTC")
  })), [])
}
```

---

### Step Scaling vs Target Tracking

| | Step Scaling | Target Tracking |
|---|---|---|
| You configure | Thresholds + scale_by steps | Only target metric value |
| AWS manages | Nothing | Scale-up and scale-down both |
| Best for | Custom multi-step rules, exact control | General-purpose APIs, smooth scaling |
| Can combine | Yes — run in parallel | Yes — run in parallel |

Both can be active at the same time. When both fire, AWS uses the most aggressive (largest) scaling action.

---

### Example A — Target Tracking on CPU (keep average at 60%)

```hcl
scaling_policies = {
  enabled = true

  cpu    = { scale_up_enabled = true, scale_down_enabled = true, ... }
  memory = { scale_up_enabled = true, scale_down_enabled = false, ... }

  target_tracking = {
    enabled            = true
    metric             = "ECSServiceAverageCPUUtilization"
    target_value       = 60     # AWS will add/remove tasks to keep CPU around 60%
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
    disable_scale_in   = false
  }
}
```

---

### Example B — Target Tracking on ALB requests per task

```hcl
target_tracking = {
  enabled                     = true
  metric                      = "ALBRequestCountPerTarget"
  target_value                = 1000   # keep at ~1000 req/task
  scale_in_cooldown           = 300
  scale_out_cooldown          = 30     # fast scale-out for traffic spikes
  alb_target_group_arn_suffix = module.svc.target_group_arns["public-alb"]
}
```

---

### Example C — Scheduled: business hours + off-peak + pre-event warmup

```hcl
scheduled_actions = [

  # Scale UP: 8am weekdays (all times UTC)
  {
    name         = "business-hours-scale-up"
    min_capacity = 4
    max_capacity = 20
    recurrence   = "cron(30 2 * * MON-FRI)"   # 8am IST = 2:30am UTC
    timezone     = "UTC"
  },

  # Scale DOWN: 10pm weekdays
  {
    name         = "off-peak-scale-down"
    min_capacity = 1
    max_capacity = 4
    recurrence   = "cron(30 16 * * MON-FRI)"  # 10pm IST = 4:30pm UTC
    timezone     = "UTC"
  },

  # One-time pre-event warmup (remove after event)
  {
    name         = "campaign-warmup"
    min_capacity = 15
    max_capacity = 30
    desired      = 15
    schedule     = "at(2026-11-27T02:00:00)"   # 30 min before event, UTC
    timezone     = "UTC"
  }
]
```

---

### Example D — Disable scale-in (pre-warm, never shrink below warmup count)

```hcl
target_tracking = {
  enabled          = true
  metric           = "ECSServiceAverageCPUUtilization"
  target_value     = 60
  disable_scale_in = true   # AWS will scale up but never scale in — pair with scheduled action to scale down
}
```

Useful when combined with a scheduled scale-down action: target tracking handles burst scale-out, scheduled action handles planned scale-down at off-peak.

---

### Outputs

```hcl
module.svc.target_tracking_policy_arn  # ARN of target tracking policy (null when disabled)
module.svc.scheduled_action_names      # list of scheduled action names
```

---

---

## Feature 4 — Deployment Circuit Breaker

### What It Does

Automatically detects failed deployments and rolls back to the last known-good task definition revision. Stops infinite restart loops on bad deploys without manual intervention.

Always enabled — no variable needed. `rollback = true` on every ECS service created by this module.

### What Was Added

```hcl
# 02_ecs_core.tf — aws_ecs_service.service
deployment_circuit_breaker {
  enable   = true
  rollback = true
}
```

### Threshold — AWS Managed (Not Configurable)

AWS automatically determines the failure threshold based on `desired_count`:

| `desired_count` | Circuit trips when |
|---|---|
| 1–9 | ALL launched tasks fail (100% failure threshold) |
| 10–100 | 10% of `desired_count` fail (minimum 10 tasks) |
| 100+ | 10% of `desired_count` fail |

**Examples:**

```
desired_count = 2  → both tasks must fail  → circuit trips → rollback
desired_count = 5  → all 5 tasks must fail → rollback
desired_count = 10 → 1 task fails (10%)    → circuit trips → rollback
desired_count = 20 → 2 tasks fail (10%)    → rollback
desired_count = 50 → 5 tasks fail (10%)    → rollback
```

### What Counts as "Failed"

- Task stops before reaching `RUNNING` state
- Task starts but fails ECS health check within `health_check_grace_period_seconds`
- Container exits with non-zero exit code

### Deployment Timeline

```
terraform apply → ECS service update accepted → apply returns success
                                   ↓
                   ECS rolls out new tasks in rolling batches
                   each task: PROVISIONING → PENDING → RUNNING
                                   │
                    ┌──────────────┴──────────────┐
                    │ task healthy                │ task fails
                    ▼                             ▼
             continues rolling             counts toward threshold
                                                  │
                                     threshold hit → deployment FAILED
                                                  │
                                     rollback = true → ECS re-deploys
                                     previous task definition revision
```

### Important Operational Note

Rollback triggers **asynchronously after** `terraform apply` returns. Terraform sees the service update accepted — not the subsequent rollback. A successful apply does not guarantee the deployment completed.

**Verify deployment status after apply:**

```bash
aws ecs describe-services \
  --cluster <cluster-name> \
  --services <service-name> \
  --query 'services[0].deployments[*].{status:status,taskDef:taskDefinition,failed:failedTasks,running:runningCount}'
```

Expected healthy output:
```json
[{ "status": "PRIMARY", "failed": 0, "running": 2 }]
```

Rollback in progress:
```json
[
  { "status": "PRIMARY",  "failed": 2, "running": 0 },
  { "status": "ACTIVE",   "failed": 0, "running": 2 }  ← previous version coming back
]
```

---

---

## Feature 5 — ECS Exec (enable_execute_command)

### What It Does

Enables SSM-based shell access into running ECS containers for debugging. Off by default — must be explicitly opted in. When enabled, the module automatically adds the required `ssmmessages:*` IAM permissions to the task role.

### Variable

```hcl
variable "enable_exec_command" {
  type    = bool
  default = false   # off by default — explicit opt-in required
}
```

### What Gets Created When `true`

```hcl
# 02_ecs_core.tf — aws_ecs_service
enable_execute_command = true

# 03_iam.tf — new policy on task role
aws_iam_policy.ecs_exec {
  ssmmessages:CreateControlChannel
  ssmmessages:CreateDataChannel
  ssmmessages:OpenControlChannel
  ssmmessages:OpenDataChannel
  Resource = "*"   # ssmmessages does not support resource-level restrictions
}
```

### Usage

```hcl
# environments/dev/terraform.tfvars
enable_exec_command = true   # debug freely in dev

# environments/prod/terraform.tfvars
enable_exec_command = false  # off — default
```

### Exec Into a Running Container

```bash
aws ecs execute-command \
  --cluster <cluster-name> \
  --task <task-arn> \
  --container <container-name> \
  --command "/bin/sh" \
  --interactive
```

### Per-Environment Recommendation

| Environment | Setting | Reason |
|---|---|---|
| `development` | `true` | Free debugging — no sensitive data |
| `staging` | `true` | Integration test support |
| `uat` | `true` | Acceptance testing support |
| `production` | `false` (default) | Shell access is a security risk — enable only per-incident with approval |

### Requirements

- Container image must include `/bin/sh` or `/bin/bash` (distroless images won't work)
- SSM Agent must be reachable: requires `ssmmessages` VPC endpoint OR NAT Gateway
- IAM user/role running `aws ecs execute-command` needs `ecs:ExecuteCommand` permission

### Security Note

ECS Exec bypasses application-level access controls — it gives direct OS-level access to the container. In production, treat `enable_exec_command = true` the same as granting SSH access to production servers.

---

---

## Feature 6 — Container Stop Timeout (stop_timeout)

### What It Does

Controls how long ECS waits after sending `SIGTERM` before force-killing the container with `SIGKILL`. Default is 30 seconds — too short for workers, JVM services, and gRPC streams.

### What Was Added

```hcl
# vars.tf — inside ecs_task_definition.container_definitions
stop_timeout = optional(number, 30)   # seconds. Fargate max = 120.
```

```json
// ecs_task.json.tpl — injected into every container definition
"stopTimeout": ${stop_timeout}
```

### Shutdown Flow

```
ECS wants to stop task (deploy, scale-down, SPOT interruption)
  │
  ▼
Sends SIGTERM → app should: finish request, close DB conn, flush logs, exit
  │
  wait stop_timeout seconds
  │
  ▼  (if still running)
Sends SIGKILL → force kill, no cleanup, in-flight work lost
```

### Recommended Values by Service Type

| Service Type | Recommended |
|---|---|
| Stateless API (short requests) | `30` (default — fine) |
| Worker (finishing a job) | `60`–`120` |
| JVM service (slow shutdown) | `60`–`90` |
| gRPC stream server | `120` |
| Celery / Sidekiq worker | `60`–`120` |

### Usage

```hcl
ecs_task_definition = {
  task_name = "notification-worker"
  container_definitions = {
    stop_timeout = 120   # wait 2 min — worker finishes current job before exit
    ...
  }
}
```

### Notes

- Fargate hard limit: **120 seconds**. Values above 120 are silently capped by AWS.
- EC2 launch type: no hard limit — can exceed 120s.
- Default `30` is backward compatible — existing callers unaffected.
- App MUST handle `SIGTERM`. If it ignores `SIGTERM`, `stop_timeout` buys time but SIGKILL still fires at the end — work is lost.

---

---

## Feature 7 — Shared Sub-Modules (Phase 3 — Planned)

> **Status: NOT IMPLEMENTED — planned for Phase 3**
> Trigger: build when `ecs-ec2-bridge-module-v3` is created. Until then, zero duplication exists and extraction adds unnecessary abstraction.

### Problem This Solves

Three sections of `ecs-fargate-module-v3` contain logic that every future ECS module will need to duplicate: IAM roles, security groups, Fluent Bit environment config. Currently embedded — no way to reuse without copy-paste.

```
Today (1 module):        Future (2+ modules):
ecs-fargate-module-v3    ecs-fargate-module-v3
  ├── 01_sgp.tf ─────┐     ├── 01_sgp.tf ─┐  ← duplicated
  ├── 03_iam.tf ─────┤     └── 03_iam.tf ─┤  ← duplicated
  └── local.tf ──────┘   ecs-ec2-bridge-v3 │
                            ├── 01_sgp.tf ─┘  ← same logic
                            └── 03_iam.tf ─┘  ← same logic
                                              → drift over time
```

### Proposed Structure

```
shared-modules/
├── ecs-iam-roles/           ← #19 — task role + exec role + vault policies
├── ecs-security-group/      ← #20 — per-task SG, VPC/peering/custom rules
└── ecs-fluentbit-config/    ← #18 — Fluent Bit env vars, stream config

ecs-fargate-module-v3/
└── calls each shared module via module "..." { source = "../shared-modules/..." }

ecs-ec2-bridge-module-v3/ (future)
└── calls same shared modules — no duplication
```

### Sub-Module Responsibilities

#### `ecs-iam-roles` (#19)

Inputs: `environment`, `cluster_prefix`, `task_name`, `aws_region`, `aws_account_id`, `secret_path_prefix`, `enable_exec_command`, `fluentbit_config`
Outputs: `task_role_arn`, `task_exec_role_arn`

Creates:
- `aws_iam_role.task_role` + trust policy
- `aws_iam_role.task_exec_role` + trust policy
- `aws_iam_policy.task_role_vault_policy` (scoped or wildcard)
- `aws_iam_policy.task_role_cross_account_policy` (when cross account set)
- `aws_iam_policy.kinesis_same_account` / `kinesis_cross_account_assume`
- `aws_iam_policy.fluentbit_s3_config`
- `aws_iam_policy.ecs_exec` (when enabled)
- `AmazonECSTaskExecutionRolePolicy` attachment

#### `ecs-security-group` (#20)

Inputs: `environment`, `cluster_prefix`, `task_name`, `vpc_id`, `vpc_cidr`, `host_port`, `configure_load_balancers`, `aditional_security_group_rules`
Outputs: `security_group_id`

Creates:
- `aws_security_group.sgp`
- `aws_security_group_rule.e01` (egress all)
- `aws_security_group_rule.i01` (VPC CIDR → host_port)
- `aws_security_group_rule.i02` (peering CIDRs → ports — all LB ports, not just primary)
- `aws_security_group_rule.ci03` (custom rules map)

> **Note:** `i02` fix (#9 — peering rule covers all LB ports) should be implemented inside this sub-module, not in `01_sgp.tf`. Defer until extraction.

#### `ecs-fluentbit-config` (#18)

Inputs: `environment`, `cluster_prefix`, `task_name`, `aws_region`, `configure_logs`, `ecs_cluster_name`
Outputs: `fluentbit_environment` (list), `fluentbit_secrets` (list)

Produces the `set_fluentbit_environment` list with all env vars (`KINESIS_REGION`, `STREAM`, `ECS_CLUSTER`, `ECS_TASK_NAME`, `ENVIRONMENT`, `KINESIS_ROLE_ARN`) that Fluent Bit sidecar reads at startup.

### When to Implement (Decision Gate)

```
Gate condition: ecs-ec2-bridge-module-v3 is created

Before gate:
  → Rule of Three not met (only 1 module)
  → Abstraction has no benefit
  → Don't extract

After gate:
  → 2 modules duplicating same code
  → Extract to shared-modules/
  → Update both modules to call shared sub-modules
  → All future modules inherit improvements automatically
```

### Migration Impact (When Implemented)

Callers of `ecs-fargate-module-v3` see **zero changes** — sub-module extraction is internal refactoring. Variable API, outputs, and behaviour stay identical. Only the internal `source` references change.

---

---

## Migration Guide — Feature 1

Feature 1 replaces `configure_alb` + `configure_dns` with `configure_load_balancers`. Any caller on the previous version must update their module call.

### Variable rename

```hcl
## BEFORE
configure_alb = {
  enabled = true
  target_group = {
    protocol             = "HTTP"
    deregistration_delay = 120
    health_check         = { path = "/" }
  }
  listener_rule = {
    enable_routing    = true
    routing_type      = "simple"
    routing_method    = "host_header"
    host_header_value = ["app.example.com"]
    alb_listener_arn  = module.alb.listener_arn
  }
}

configure_dns = {
  use_route53_dns_zone = true
  add_dns_record = {
    public_dns_zone = module.zone.zone_id
    alb_hostname    = module.alb.dns_name
    alb_zoneid      = module.alb.zone_id
  }
}

## AFTER
configure_load_balancers = [
  {
    name           = "main-alb"
    type           = "alb"
    container_port = 8000          # ← add: explicit port per LB entry

    target_group = {
      protocol             = "HTTP"
      deregistration_delay = 120
      health_check         = { path = "/" }
    }

    listener_rule = {
      enable_routing    = true
      listener_arn      = module.alb.listener_arn      # ← renamed: alb_listener_arn → listener_arn
      routing_type      = "simple"
      routing_method    = "host_header"
      host_header_value = ["app.example.com"]
    }

    dns = {
      enabled        = true
      hosted_zone_id = module.zone.zone_id              # ← merged from configure_dns
      lb_dns_name    = module.alb.dns_name
      lb_zone_id     = module.alb.zone_id
    }
  }
]
```

### Output reference rename

```hcl
## BEFORE — single string outputs
module.svc.target_group_arn   → string
module.svc.listener_rule_arn  → string
module.svc.dns_record_fqdn    → string

## AFTER — map outputs keyed by LB name
module.svc.target_group_arns["main-alb"]   → string
module.svc.listener_rule_arns["main-alb"]  → string
module.svc.dns_record_fqdns["main-alb"]    → string
```
