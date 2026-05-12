# cluster

ECS cluster with configurable capacity providers: Fargate, FARGATE_SPOT, and EC2 (Auto Scaling Group).
Supports awsvpc networking (Fargate + EC2) and bridge mode (EC2 only).

[![Terraform](https://img.shields.io/badge/Terraform-1.3+-7B42BC.svg)](https://www.terraform.io/)
[![AWS Provider](https://img.shields.io/badge/AWS%20Provider-5.0+-FF9900.svg)](https://registry.terraform.io/providers/hashicorp/aws/latest)

---

## Features

- **Fargate** — serverless, awsvpc networking, zero instance management
- **FARGATE_SPOT** — up to 70% cheaper, tolerates 2-min interruption warning (SIGTERM)
- **EC2 Capacity Provider** — ASG-backed; enables bridge mode, GPU instances, high-density task packing; ECS managed scaling
- **Cluster default strategy** — configurable `base` + `weight` per provider; individual services can override
- **Container Insights** — toggle `disabled` / `enabled` / `enhanced`
- **Service Discovery** — create new or attach existing Cloud Map private DNS namespace (for Service Connect)

---

## Naming Convention

```
{environment}-{cluster_name}-cluster

environment = "production", cluster_name = "platform"
→ production-platform-cluster
```

---

## Usage

### Fargate only (default)

```hcl
module "ecs_cluster" {
  source = "github.com/etc-binstack/terraform-aws//modules/ecs/cluster?ref=v1.0.0"

  enable_module = true
  environment   = "production"
  cluster_name  = "platform"

  tags = {
    Environment = "production"
    ManagedBy   = "terraform"
  }
}
```

### Fargate + FARGATE_SPOT (cost-optimised production)

```hcl
module "ecs_cluster" {
  source = "github.com/etc-binstack/terraform-aws//modules/ecs/cluster?ref=v1.0.0"

  enable_module = true
  environment   = "production"
  cluster_name  = "platform"

  capacity_providers = {
    fargate = {
      enabled        = true
      default_base   = 1    # always 1 guaranteed Fargate task
      default_weight = 1
    }
    fargate_spot = {
      enabled        = true
      default_base   = 0
      default_weight = 3    # 3x more tasks on SPOT than Fargate
    }
    ec2 = { enabled = false }
  }
}
```

### EC2 capacity provider (bridge mode / GPU / high-density)

```hcl
module "ecs_cluster" {
  source = "github.com/etc-binstack/terraform-aws//modules/ecs/cluster?ref=v1.0.0"

  enable_module = true
  environment   = "production"
  cluster_name  = "platform"

  capacity_providers = {
    fargate      = { enabled = false }
    fargate_spot = { enabled = false }

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
      default_weight                 = 1
    }
  }
}
```

### Container Insights enabled

```hcl
module "ecs_cluster" {
  source = "github.com/etc-binstack/terraform-aws//modules/ecs/cluster?ref=v1.0.0"

  enable_module = true
  environment   = "production"
  cluster_name  = "platform"

  monitoring_settings = [
    {
      name  = "containerInsights"
      value = "enabled"   # "enabled" | "enhanced" | "disabled"
    }
  ]
}
```

### Service Connect — create new namespace

```hcl
module "ecs_cluster" {
  source = "github.com/etc-binstack/terraform-aws//modules/ecs/cluster?ref=v1.0.0"

  enable_module = true
  environment   = "production"
  cluster_name  = "platform"

  namespace_configuration = {
    enabled        = true
    create_new     = true
    namespace_name = "production-services"
    vpc_id         = module.vpc.vpc_id
  }
}
```

### Service Connect — attach existing namespace

```hcl
namespace_configuration = {
  enabled            = true
  create_new         = false
  existing_namespace = "production-services"   # existing Cloud Map namespace name
  namespace_name     = null
  vpc_id             = module.vpc.vpc_id
}
```

---

## Resources Created

All resources require `enable_module = true` as the base condition.

### Always created

| Resource | Notes |
|---|---|
| `aws_ecs_cluster` | Cluster with name `{environment}-{cluster_name}-cluster` |
| `aws_ecs_cluster_capacity_providers` | Registers active providers + default strategy on the cluster |

### Conditional resources

| Resource | Condition |
|---|---|
| `aws_cloudwatch_log_group` | `monitoring_settings.containerInsights = "enabled"` or `"enhanced"` |
| `aws_service_discovery_private_dns_namespace` | `namespace_configuration.enabled = true` AND `create_new = true` |
| `data.aws_service_discovery_dns_namespace` | `namespace_configuration.enabled = true` AND `create_new = false` |
| `data.aws_ssm_parameter` (ECS AMI) | `ec2.enabled = true` AND `ec2.ami_id = null` |
| `aws_iam_role` (EC2 instance role) | `ec2.enabled = true` |
| `aws_iam_role_policy_attachment` — `AmazonEC2ContainerServiceforEC2Role` | `ec2.enabled = true` |
| `aws_iam_role_policy_attachment` — `AmazonSSMManagedInstanceCore` | `ec2.enabled = true` |
| `aws_iam_role_policy_attachment` — additional | `ec2.enabled = true` AND `additional_iam_policy_arns` non-empty |
| `aws_iam_instance_profile` | `ec2.enabled = true` |
| `aws_launch_template` | `ec2.enabled = true` |
| `aws_autoscaling_group` | `ec2.enabled = true` |
| `aws_ecs_capacity_provider` | `ec2.enabled = true` |

---

## Inputs

### Top-level variables

| Variable | Type | Default | Required | Description |
|---|---|---|---|---|
| `enable_module` | `bool` | `false` | no | Master toggle. `false` = destroy all resources without removing config |
| `environment` | `string` | — | yes | `development` \| `staging` \| `uat` \| `production` |
| `cluster_name` | `string` | — | yes | Combined with environment to form cluster name |
| `tags` | `map(string)` | `{}` | no | Applied to all taggable resources |
| `monitoring_settings` | `list(object)` | `containerInsights=disabled` | no | Container Insights configuration |
| `namespace_configuration` | `object` | disabled | no | Cloud Map namespace for Service Connect |
| `capacity_providers` | `object` | `fargate=enabled` | no | Fargate / FARGATE_SPOT / EC2 configuration |

### `monitoring_settings` validation

| Rule | Detail |
|---|---|
| `containerInsights` value | Must be `enabled`, `enhanced`, or `disabled` |
| `name` field | Cannot be null or empty |
| `value` field | Cannot be null or empty |

### `namespace_configuration` fields

| Field | Type | Default | Description |
|---|---|---|---|
| `enabled` | `bool` | `false` | Toggle namespace |
| `create_new` | `bool` | `true` | `true` = create new namespace. `false` = attach existing |
| `namespace_name` | `string` | `null` | Required when `create_new = true` |
| `existing_namespace` | `string` | `null` | Required when `create_new = false` |
| `vpc_id` | `string` | `null` | Required when `enabled = true` |

### `capacity_providers.fargate` and `.fargate_spot` fields

| Field | Default | Description |
|---|---|---|
| `enabled` | `fargate=true`, `fargate_spot=false` | Toggle this provider |
| `default_base` | `0` | Minimum tasks always placed on this provider across the cluster |
| `default_weight` | `fargate=1`, `fargate_spot=0` | Relative share of new tasks (0 = only used for `base`) |

### `capacity_providers.ec2` fields

| Field | Default | Condition | Description |
|---|---|---|---|
| `enabled` | `false` | — | Create EC2 capacity provider (ASG + launch template + IAM) |
| `instance_type` | `t3.medium` | `enabled=true` | EC2 instance type |
| `ami_id` | `null` | `enabled=true` | `null` = auto-resolve latest ECS-optimized Amazon Linux 2 via SSM |
| `key_name` | `null` | `enabled=true` | EC2 key pair name for SSH. `null` = no key |
| `extra_user_data` | `""` | `enabled=true` | Shell commands appended after base ECS bootstrap |
| `additional_iam_policy_arns` | `[]` | `enabled=true` | Extra IAM policies attached to EC2 instance role |
| `min_size` | `0` | `enabled=true` | ASG minimum instance count |
| `max_size` | `5` | `enabled=true` | ASG maximum instance count |
| `desired_capacity` | `1` | `enabled=true` | ASG initial desired count (ignored by ECS managed scaling after first deploy) |
| `vpc_zone_identifier` | `[]` | `enabled=true` | Private subnet IDs for ASG placement |
| `managed_scaling_enabled` | `true` | `enabled=true` | ECS adjusts EC2 count based on task placement demand. Also gates `managed_termination_protection` and `protect_from_scale_in` |
| `managed_scaling_target` | `80` | `managed_scaling_enabled=true` | Target % EC2 capacity utilization before scaling out. `80` = 20% headroom kept warm |
| `managed_draining_enabled` | `true` | `enabled=true` | Drain running tasks from instances before termination |
| `instance_warmup_period` | `300` | `managed_scaling_enabled=true` | Seconds before a new instance's capacity is counted by managed scaling. Prevents over-provisioning during boot |
| `minimum_scaling_step_size` | `1` | `managed_scaling_enabled=true` | Minimum instances added/removed per scaling action |
| `maximum_scaling_step_size` | `10` | `managed_scaling_enabled=true` | Maximum instances added/removed per scaling action |
| `default_base` | `0` | `enabled=true` | Minimum tasks placed on EC2 provider by cluster default strategy |
| `default_weight` | `0` | `enabled=true` | Relative share of new tasks in cluster default strategy |

---

## Outputs

### Always available (when `enable_module = true`)

| Output | Description |
|---|---|
| `cluster_id` | ECS cluster ID |
| `cluster_name` | ECS cluster name |
| `cluster_arn` | ECS cluster ARN |
| `ecs_cluster_id` | Alias for `cluster_id` (backward compat) |
| `ecs_cluster_name` | Alias for `cluster_name` (backward compat) |
| `active_capacity_providers` | List of capacity provider names registered on cluster |

### EC2 outputs (when `ec2.enabled = true`)

| Output | Description |
|---|---|
| `ec2_capacity_provider_name` | Provider name — pass to `service-awsvpc` `capacity_provider_strategy` |
| `ec2_asg_arn` | Auto Scaling Group ARN |
| `ec2_asg_name` | Auto Scaling Group name |
| `ec2_launch_template_id` | Launch template ID |
| `ec2_instance_role_arn` | IAM instance role ARN |

### Namespace outputs (when `namespace_configuration.enabled = true`)

| Output | Description |
|---|---|
| `ecs_namespace_id` | Cloud Map namespace ID |
| `ecs_namespace_arn` | Cloud Map namespace ARN |
| `ecs_namespace_name` | Cloud Map namespace name |
| `namespace_source` | `"created"` \| `"existing"` \| `"disabled"` |

---

## Wiring to Service Module

### Fargate service on this cluster

```hcl
module "api_service" {
  source = "../service-awsvpc"

  configure_ecs_service = {
    ecs_cluster_id   = module.ecs_cluster.cluster_id
    ecs_cluster_name = module.ecs_cluster.cluster_name
    launch_type      = "FARGATE"
    scaling_capacity = { desired_count = 2, min_capacity = 1, max_capacity = 10 }
  }
}
```

### EC2 capacity provider service (awsvpc or bridge)

```hcl
module "worker_service" {
  source = "../service-awsvpc"

  configure_ecs_service = {
    ecs_cluster_id   = module.ecs_cluster.cluster_id
    ecs_cluster_name = module.ecs_cluster.cluster_name

    # Reference EC2 provider by name from cluster output
    capacity_provider_strategy = [
      {
        capacity_provider = module.ecs_cluster.ec2_capacity_provider_name
        weight            = 1
        base              = 0
      }
    ]
    task_compatibilities = ["EC2"]
    scaling_capacity = { desired_count = 2, min_capacity = 1, max_capacity = 10 }
  }
}
```

### Service Connect (Cloud Map namespace)

```hcl
module "api_service" {
  source = "../service-awsvpc"

  configure_ecs_service = {
    ecs_cluster_id   = module.ecs_cluster.cluster_id
    ecs_cluster_name = module.ecs_cluster.cluster_name
    launch_type      = "FARGATE"

    service_connect = {
      enabled        = true
      namespace_name = module.ecs_cluster.ecs_namespace_name
    }
    scaling_capacity = { desired_count = 2, min_capacity = 1, max_capacity = 10 }
  }
}
```

---

## Network Mode Compatibility

One cluster handles all four networking modes. Network mode is a **task definition** setting — not a cluster setting. The cluster just needs the right capacity provider registered.

| Mode | Capacity Provider | Fargate | FARGATE_SPOT | EC2 |
|---|---|---|---|---|
| `awsvpc` — Fargate | `FARGATE` | ✅ | — | — |
| `awsvpc` — Fargate SPOT | `FARGATE_SPOT` | — | ✅ | — |
| `awsvpc` — EC2 | `EC2` | — | — | ✅ |
| `bridge` — EC2 | `EC2` | — | — | ✅ |

**Hard AWS rule:** Fargate and FARGATE_SPOT support `awsvpc` only. Bridge mode requires EC2 capacity provider.

```
Same cluster, same EC2 instances — all at once:
├── Service A → FARGATE      → network_mode = awsvpc  (own ENI + IP per task)
├── Service B → FARGATE_SPOT → network_mode = awsvpc  (own ENI + IP per task)
├── Service C → EC2          → network_mode = awsvpc  (own ENI + IP per task)
└── Service D → EC2          → network_mode = bridge  (shared host IP, dynamic port)
```

Enable the EC2 provider once → covers both `awsvpc` and `bridge` tasks on the same EC2 instances simultaneously.

---

## Capacity Provider — Base and Weight Logic

AWS fills tasks in two phases: base first, then weight distribution.

```
Phase 1 — satisfy base (guaranteed regardless of interruption)
Phase 2 — distribute remaining tasks proportionally by weight

FARGATE base=1 weight=1 + FARGATE_SPOT base=0 weight=3:
  desired=1  → [1 FARGATE]               base satisfied
  desired=4  → [1 FARGATE] [3 SPOT]      base + 3 remaining split 1:3
  desired=8  → [2 FARGATE] [6 SPOT]      base + 7 remaining: 25%/75%
  desired=12 → [3 FARGATE] [9 SPOT]      base + 11 remaining: 25%/75%
```

The cluster `default_capacity_provider_strategy` is the fallback. Individual services set via `capacity_provider_strategy` in the service module override it.

---

## Safe EC2 Disable Sequence

**Warning:** Setting `enabled = false` directly will fail if instances have scale-in protection. Use this two-step sequence.

**Step 1** — disable managed scaling (removes all protections):
```hcl
ec2 = {
  enabled                 = true    # keep enabled
  managed_scaling_enabled = false   # disables managed_termination_protection + protect_from_scale_in
  min_size                = 0
  max_size                = 0
}
```
Run `terraform apply`. ECS stops managing instances. ASG scales to zero.

**Step 2** — destroy resources:
```hcl
ec2 = { enabled = false }
```
Run `terraform apply`. `force_delete = true` on the ASG ensures clean destruction.

### If `terraform apply` hangs on capacity provider deletion

AWS blocks capacity provider deletion while it is still registered to the cluster. Terraform may hang at:

```
aws_ecs_capacity_provider.ec2[0]: Still destroying... [10s elapsed]
```

**Unblock manually:**

```bash
# 1. Deregister EC2 capacity provider from cluster
# Replace --capacity-providers and --default-capacity-provider-strategy
# with whatever providers remain active on your cluster (e.g. FARGATE, FARGATE_SPOT)
aws ecs put-cluster-capacity-providers \
  --cluster <cluster-name> \
  --capacity-providers FARGATE \
  --default-capacity-provider-strategy capacityProvider=FARGATE,weight=1,base=1 \
  --region <region>
```

Wait ~15s for AWS to process, then:

```bash
# 2. Delete the capacity provider
aws ecs delete-capacity-provider \
  --capacity-provider <cluster-name>-ec2-cp \
  --region <region>
```

Then run `terraform apply` again. Remaining resources (ASG, launch template, IAM) will destroy cleanly.

> **Note:** This is an AWS API eventual consistency constraint — `put-cluster-capacity-providers` returns success before fully deregistering the provider internally. There is no Terraform-native workaround.

---

## EC2 Instance Bootstrap (user_data)

Base user data injected automatically into every EC2 instance:

```bash
#!/bin/bash
echo ECS_CLUSTER={cluster-name} >> /etc/ecs/ecs.config
echo ECS_ENABLE_TASK_ENI=true >> /etc/ecs/ecs.config
```

`ECS_ENABLE_TASK_ENI=true` enables awsvpc task networking on EC2. Bridge mode tasks also work — they don't use task ENIs but the setting doesn't prevent them.

Additional commands via `extra_user_data`:
```hcl
ec2 = {
  extra_user_data = <<-EOF
    echo ECS_RESERVED_MEMORY=256 >> /etc/ecs/ecs.config
    yum install -y amazon-cloudwatch-agent
  EOF
}
```

---

## Requirements

| Name | Version |
|---|---|
| terraform | >= 1.3 |
| aws | >= 5.0 |
| random | >= 3.0 |

---

## License

Apache 2.0 — see [LICENSE](../../../LICENSE)
