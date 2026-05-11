# Fargate Only

**Pattern:** Serverless cluster, zero instance management
**Use for:** Standard Fargate workloads — APIs, workers, schedulers
**Concepts:** FARGATE capacity provider, cluster default strategy
**Adopt for:** Most production services that don't need EC2, GPU, or bridge mode

---

## What This Creates

- ECS cluster (`{environment}-{cluster_name}-cluster`)
- `aws_ecs_cluster_capacity_providers` — FARGATE registered
- No EC2 instances, no ASG, no launch template

---

## Key Concepts

**Cluster default strategy vs service override**
`default_base` and `default_weight` set the cluster-level fallback. Any service calling `launch_type = "FARGATE"` ignores this — it uses the provider explicitly. Default strategy only applies when a service sets no `launch_type` and no `capacity_provider_strategy`.

---

## Configuration

```hcl
module "ecs_cluster" {
  source = "github.com/etc-binstack/terraform-aws//modules/ecs/cluster?ref=v1.0.0"

  enable_module = true
  environment   = var.environment
  cluster_name  = "platform"
  tags          = var.common_tags

  capacity_providers = {
    fargate      = { enabled = true }
    fargate_spot = { enabled = false }
    ec2          = { enabled = false }
  }
}
```

---

---

# FARGATE_SPOT Only

**Pattern:** Cost-optimised cluster for interruption-tolerant workloads
**Use for:** Background workers, queue consumers, batch processors where 2-min interruption is acceptable
**Concepts:** FARGATE_SPOT capacity provider, SIGTERM handling requirement
**Adopt for:** Queue workers (SQS/RabbitMQ/Kafka), email senders, image processors, report generators

---

## What This Creates

- ECS cluster
- `aws_ecs_cluster_capacity_providers` — FARGATE_SPOT registered only

---

## Key Concepts

**FARGATE_SPOT interruption**
AWS sends SIGTERM 2 minutes before reclaiming the task. Application MUST handle SIGTERM gracefully — finish current job, flush logs, exit(0). If it doesn't, SIGKILL fires and in-flight work is lost.

**No guaranteed capacity**
`base = 0` means zero guaranteed tasks. If SPOT capacity is unavailable in your region/AZ, tasks won't start. For critical services, add `fargate.enabled = true` with `base = 1` as fallback.

---

## Configuration

```hcl
module "ecs_cluster" {
  source = "github.com/etc-binstack/terraform-aws//modules/ecs/cluster?ref=v1.0.0"

  enable_module = true
  environment   = var.environment
  cluster_name  = "platform"
  tags          = var.common_tags

  capacity_providers = {
    fargate      = { enabled = false }
    fargate_spot = { enabled = true, default_base = 0, default_weight = 1 }
    ec2          = { enabled = false }
  }
}
```

---

---

# Mixed Fargate + FARGATE_SPOT

**Pattern:** Production cluster with guaranteed base + cost-optimised scale
**Use for:** Production services that need HA (min 1 guaranteed task) but want cost savings at scale
**Concepts:** `default_base` guarantees minimum, `default_weight` controls proportional distribution
**Adopt for:** Any production API or service with variable load

---

## What This Creates

- ECS cluster
- `aws_ecs_cluster_capacity_providers` — both FARGATE and FARGATE_SPOT registered
- Cluster default strategy: 1 guaranteed Fargate + 3x more on SPOT

---

## Key Concepts

**Base + weight distribution**
```
FARGATE base=1 weight=1  +  FARGATE_SPOT base=0 weight=3:

desired=1  → 1 FARGATE  (base satisfied, nothing remaining)
desired=4  → 1 FARGATE + 3 SPOT
desired=8  → 2 FARGATE + 6 SPOT  (25% / 75% split)
```

**Service-level override**
Individual services can set their own `capacity_provider_strategy` to ignore the cluster default. A SPOT-only worker service on this cluster simply sets `capacity_provider_strategy = [{ FARGATE_SPOT, weight=1, base=0 }]`.

---

## Configuration

```hcl
module "ecs_cluster" {
  source = "github.com/etc-binstack/terraform-aws//modules/ecs/cluster?ref=v1.0.0"

  enable_module = true
  environment   = var.environment
  cluster_name  = "platform"
  tags          = var.common_tags

  capacity_providers = {
    fargate = {
      enabled        = true
      default_base   = 1
      default_weight = 1
    }
    fargate_spot = {
      enabled        = true
      default_base   = 0
      default_weight = 3
    }
    ec2 = { enabled = false }
  }
}
```

---

---

# EC2 Capacity Provider (awsvpc)

**Pattern:** EC2-backed cluster for awsvpc tasks needing specific instance types
**Use for:** Stateful services (OpenSearch, databases), GPU workloads, high-memory tasks
**Concepts:** ASG + ECS managed scaling, EC2 capacity provider, awsvpc on EC2
**Adopt for:** OpenSearch nodes, ML inference servers, JVM services needing instance store

---

## What This Creates

- ECS cluster
- EC2 capacity provider: launch template + ASG + IAM instance role + instance profile
- `AmazonEC2ContainerServiceforEC2Role` + `AmazonSSMManagedInstanceCore` attached to instance role
- ECS managed scaling on the ASG

---

## Prerequisites

- VPC with private subnets
- Security group on the EC2 instances (managed outside this module)

---

## Key Concepts

**ECS managed scaling**
When `managed_scaling_enabled = true`, ECS automatically scales the ASG up/down based on task placement demand. `managed_scaling_target = 80` means ECS scales out when EC2 capacity is 80% utilised.

**`desired_capacity` is advisory**
After first deploy, ECS managed scaling owns `desired_capacity`. The value in the module is only the initial count. Terraform `ignore_changes = [desired_capacity]` prevents drift on subsequent applies.

**AMI auto-resolve**
`ami_id = null` resolves the latest ECS-optimized Amazon Linux 2 AMI via SSM at plan time. Pin a specific AMI ID in production to prevent unexpected instance replacements on AMI updates.

---

## Configuration

```hcl
module "ecs_cluster" {
  source = "github.com/etc-binstack/terraform-aws//modules/ecs/cluster?ref=v1.0.0"

  enable_module = true
  environment   = var.environment
  cluster_name  = "platform"
  tags          = var.common_tags

  capacity_providers = {
    fargate      = { enabled = false }
    fargate_spot = { enabled = false }

    ec2 = {
      enabled                        = true
      instance_type                  = "m5.large"
      ami_id                         = null          # auto-resolve ECS-optimized AMI
      min_size                       = 1
      max_size                       = 10
      desired_capacity               = 2             # initial only — ECS owns this after first apply
      vpc_zone_identifier            = module.vpc.private_subnet_ids
      managed_scaling_enabled        = true
      managed_scaling_target         = 80            # 20% headroom kept warm
      managed_draining_enabled       = true          # drain tasks before instance termination
      instance_warmup_period         = 300           # 5m before new instance capacity is counted
      minimum_scaling_step_size      = 1
      maximum_scaling_step_size      = 10
      default_base                   = 0
      default_weight                 = 1
    }
  }
}
```

## Notes

- **Security group:** EC2 instances need a SG allowing ECS agent traffic. Manage outside this module and attach via `extra_user_data` or launch template SG reference.
- **Pin AMI in prod:** `ami_id = data.aws_ssm_parameter.ecs_ami.value` — pin to a tested AMI version.
- **`desired_capacity` is advisory:** ECS managed scaling owns it after first apply. Changing it in Terraform has no effect.
- **Safe disable:** Set `managed_scaling_enabled = false` first (apply), then set `enabled = false` (apply). Never jump straight to `enabled = false` with running instances.
- **Related:** `service-awsvpc` module — set `capacity_provider_strategy` to `ec2_capacity_provider_name` output.

---

---

# EC2 Capacity Provider (bridge mode)

**Pattern:** High-density EC2 cluster for bridge mode tasks
**Use for:** Many lightweight tasks per EC2 instance — no ENI limit, shared host IP
**Concepts:** EC2 bridge mode, dynamic port mapping, `target_type = "instance"` ALB
**Adopt for:** High-density workers, legacy services, services with many small tasks on shared hosts

---

## What This Creates

Same as EC2 (awsvpc) — same cluster resources. Bridge mode is configured at the **service/task** level, not here. This example just shows the correct cluster config to enable bridge mode services.

---

## Key Concepts

**Bridge mode is a task definition setting, not cluster**
The cluster registers an EC2 capacity provider. The service module sets `network_mode = "bridge"` in the task definition. One EC2 instance can run both `awsvpc` and `bridge` tasks simultaneously.

**ENI limit does not apply to bridge mode**
`awsvpc` tasks each need one ENI → limited to 3-14 tasks per EC2 instance depending on instance type.
`bridge` tasks share the host ENI → limited only by CPU/RAM → 20+ tasks per instance possible.

**Dynamic port mapping**
Bridge tasks use `host_port = 0` → Docker assigns a random host port at runtime. ALB must use `target_type = "instance"` (not `"ip"`) to register instance + dynamic port pairs.

---

## Configuration

```hcl
## Cluster — same EC2 provider as awsvpc example
module "ecs_cluster" {
  source = "github.com/etc-binstack/terraform-aws//modules/ecs/cluster?ref=v1.0.0"

  enable_module = true
  environment   = var.environment
  cluster_name  = "platform"
  tags          = var.common_tags

  capacity_providers = {
    fargate      = { enabled = true  }   # awsvpc Fargate services still work
    fargate_spot = { enabled = false }
    ec2 = {
      enabled                        = true
      instance_type                  = "c5.xlarge"   # CPU-optimised for many small tasks
      min_size                       = 2
      max_size                       = 20
      desired_capacity               = 2
      vpc_zone_identifier            = module.vpc.private_subnet_ids
      managed_scaling_enabled        = true
      managed_scaling_target         = 80
      managed_draining_enabled       = true
      instance_warmup_period         = 300
      minimum_scaling_step_size      = 1
      maximum_scaling_step_size      = 10
    }
  }
}

## Service — bridge mode set in service-bridge module (future)
## service-awsvpc does NOT support bridge mode
## Use service-bridge module when available (Phase 3)
```

---

---

# All Providers + Container Insights + Service Connect

**Pattern:** Full-featured cluster for multi-service platform
**Use for:** Platform cluster hosting many services with different compute needs
**Concepts:** All three providers, Container Insights, Cloud Map namespace for Service Connect
**Adopt for:** Production platform cluster where services independently choose Fargate/SPOT/EC2

---

## What This Creates

- ECS cluster with all three capacity providers registered
- CloudWatch Container Insights log group
- Cloud Map private DNS namespace for Service Connect
- EC2 launch template + ASG + IAM role

---

## Key Concepts

**Per-service provider selection**
Registering all three providers on one cluster does NOT mean all services use all three. Each service picks its provider via `capacity_provider_strategy` or `launch_type`. The cluster default strategy is just the fallback.

**Container Insights**
`value = "enhanced"` enables deeper metrics (task-level CPU/memory breakdown, storage I/O). Higher cost than `"enabled"`. Use `"enabled"` unless you need task-level granularity.

**Service Connect namespace**
One namespace per cluster. All services in the cluster that enable Service Connect register under `{service-name}.{namespace}`. Services discover each other via DNS without hardcoded IPs.

---

## Configuration

```hcl
module "ecs_cluster" {
  source = "github.com/etc-binstack/terraform-aws//modules/ecs/cluster?ref=v1.0.0"

  enable_module = true
  environment   = var.environment
  cluster_name  = "platform"
  tags          = var.common_tags

  monitoring_settings = [
    { name = "containerInsights", value = "enabled" }
  ]

  capacity_providers = {
    fargate = {
      enabled        = true
      default_base   = 1
      default_weight = 1
    }
    fargate_spot = {
      enabled        = true
      default_base   = 0
      default_weight = 3
    }
    ec2 = {
      enabled                        = true
      instance_type                  = "m5.large"
      min_size                       = 1
      max_size                       = 10
      desired_capacity               = 2
      vpc_zone_identifier            = module.vpc.private_subnet_ids
      managed_scaling_enabled        = true
      managed_scaling_target         = 80
      managed_draining_enabled       = true
      instance_warmup_period         = 300
      minimum_scaling_step_size      = 1
      maximum_scaling_step_size      = 10
      default_base                   = 0
      default_weight                 = 0   # services opt-in explicitly
    }
  }

  namespace_configuration = {
    enabled        = true
    create_new     = true
    namespace_name = "${var.environment}-services"
    vpc_id         = module.vpc.vpc_id
  }
}
```

## Notes

- **EC2 `default_weight = 0`** means EC2 is available but not in the cluster default strategy. Services explicitly set `capacity_provider_strategy = [{ ec2_capacity_provider_name, weight=1 }]` to use it.
- **Namespace name** is the DNS suffix. Service `billing-api` on this cluster resolves as `billing-api.production-services` within the VPC.
- **Related:** `service-awsvpc` → pass `module.ecs_cluster.ecs_namespace_name` to `configure_ecs_service.service_connect.namespace_name`.
