# service-awsvpc

Production-ready ECS Fargate / EC2 service module (awsvpc networking). One module call provisions the full stack: task definition, ECS service, load balancer, autoscaling, alerting, and DNS.

[![Terraform](https://img.shields.io/badge/Terraform-1.3+-7B42BC.svg)](https://www.terraform.io/)
[![AWS Provider](https://img.shields.io/badge/AWS%20Provider-5.0+-FF9900.svg)](https://registry.terraform.io/providers/hashicorp/aws/latest)
[![ECS](https://img.shields.io/badge/ECS-Fargate%20%2F%20EC2-FF9900.svg)](https://aws.amazon.com/ecs/)

---

## Features

- **Multiple Load Balancers** — ALB + NLB simultaneously; `host_header`, `path_pattern`, `mixed_route` routing; per-LB Route53 DNS
- **Capacity Provider Strategy** — FARGATE, FARGATE_SPOT, EC2, or mixed with weighted distribution
- **FireLens Logging** — Fluent Bit sidecar → Kinesis; same-account and cross-account (central logs account)
- **Autoscaling** — Step scaling (CPU/Memory) + Target tracking + Scheduled actions (cron + one-time)
- **Deployment Safety** — Circuit breaker with auto-rollback; `propagate_tags`; configurable `stop_timeout`
- **ECS Exec** — Optional SSM shell access (`enable_exec_command`), off by default
- **Secrets** — AWS Secrets Manager + SSM Parameter Store injection; scoped IAM via `secret_path_prefix`
- **EFS Volumes** — IAM-authorized access point mounts
- **Command & Entrypoint Override** — Run same image as API, worker, or scheduler
- **Service Connect** — Cloud Map DNS with built-in circuit breaking

---

## Usage

```hcl
module "api" {
  source = "github.com/etc-binstack/terraform-aws//modules/ecs/service-awsvpc?ref=v1.0.0"

  enable_module      = true
  environment        = "production"
  aws_region         = "<your-region>"
  aws_account_id     = "123456789012"
  ecs_cluster_prefix = "platform"

  ecs_task_definition = {
    task_name = "restsvc-api"
    container_definitions = {
      container_image = "111122223333.dkr.ecr.<your-region>.amazonaws.com/restsvc-api:v1.0.0"
      container_port  = 8000
      fargate_cpu     = 512
      fargate_memory  = 1024
    }
  }

  network_configuration = {
    vpc_id         = module.vpc.vpc_id
    vpc_subnet_ids = module.vpc.private_subnet_ids
    vpc_cidr       = module.vpc.vpc_cidr
  }

  configure_load_balancers = [
    {
      name           = "public-alb"
      type           = "alb"
      container_port = 8000
      listener_rule  = { listener_arn = module.alb.https_listener_arn, routing_type = "simple", routing_method = "host_header", host_header_value = ["api.example.com"] }
      dns            = { enabled = true, hosted_zone_id = module.zone.zone_id, lb_dns_name = module.alb.dns_name, lb_zone_id = module.alb.zone_id }
    }
  ]

  configure_ecs_service = {
    ecs_cluster_id   = module.ecs_cluster.cluster_id
    ecs_cluster_name = module.ecs_cluster.cluster_name
    launch_type      = "FARGATE"
    scaling_capacity = { desired_count = 2, min_capacity = 1, max_capacity = 10 }
  }

  scaling_policies = {
    enabled = true
    cpu    = { scale_up_enabled = true, scale_down_enabled = true, scale_up = { threshold = 70, evaluation_periods = 3, period = 60, cooldown = 60, lower_bound = 0, scale_by = 1 }, scale_down = { threshold = 20, evaluation_periods = 5, period = 60, cooldown = 300, upper_bound = 0, scale_by = -1 } }
    memory = { scale_up_enabled = true, scale_down_enabled = false, scale_up = { threshold = 80, evaluation_periods = 3, period = 60, cooldown = 60, lower_bound = 0, scale_by = 1 }, scale_down = { threshold = 0, evaluation_periods = 1, period = 60, cooldown = 60, upper_bound = 0, scale_by = 0 } }
  }

  configure_alerts = {
    enabled         = true
    topic_name      = "alerts"
    email_endpoints = ["oncall@example.com"]
    enabled_alerts  = { cpu_high = true, cpu_low = false, memory_high = true, memory_low = false }
  }
}
```

See [`examples/`](./examples/) for complete and minimal runnable configurations.

---

## Resources Created

| Resource | Condition |
|---|---|
| `aws_ecs_task_definition` | Always |
| `aws_ecs_service` | Always |
| `aws_iam_role` × 2 (task + execution) | Always |
| `aws_security_group` + rules | Always |
| `aws_cloudwatch_log_group` | Always |
| `aws_lb_target_group` | Per `configure_load_balancers` entry |
| `aws_lb_listener_rule` | Per LB with `enable_routing = true` |
| `aws_route53_record` | Per LB with `dns.enabled = true` |
| `aws_appautoscaling_target` + policies | `scaling_policies.enabled = true` |
| `aws_appautoscaling_scheduled_action` | `scaling_policies.scheduled_actions` non-empty |
| `aws_sns_topic` + subscriptions | `configure_alerts.enabled = true` |
| FireLens sidecar container | `configure_logs.enable_fluentbit = true` |
| Kinesis IAM policy | `enable_fluentbit = true` |
| ECS Exec IAM policy | `enable_exec_command = true` |

---

## Inputs

See [`docs/variables.md`](./docs/variables.md) for full descriptions and validation rules.

| Variable | Type | Default | Description |
|---|---|---|---|
| `enable_module` | `bool` | `false` | Master toggle |
| `enable_exec_command` | `bool` | `false` | ECS Exec SSM shell access |
| `environment` | `string` | — | `development` \| `staging` \| `uat` \| `production` |
| `aws_region` | `string` | `us-east-1` | AWS region |
| `aws_account_id` | `string` | — | 12-digit account ID |
| `aws_cross_account_id` | `string` | `null` | Cross-account for secrets |
| `ecs_cluster_prefix` | `string` | `demo-cluster` | Used in resource naming |
| `secret_path_prefix` | `string` | `null` | Scope Secrets Manager IAM (opt-in) |
| `cross_account_secret_path_prefix` | `string` | `null` | Scope cross-account Secrets Manager IAM |
| `common_tags` | `map(string)` | `{}` | Tags on all resources |
| `random_suffix` | `string` | `""` | IAM role name suffix |
| `ecs_task_definition` | `object` | — | Container, secrets, volumes, logging config |
| `network_configuration` | `object` | — | VPC, subnets, security group rules |
| `configure_load_balancers` | `list(object)` | `[]` | ALB/NLB attachments |
| `configure_ecs_service` | `object` | — | Launch type, capacity, service connect |
| `scaling_policies` | `object` | — | Step, target tracking, scheduled scaling |
| `configure_alerts` | `object` | — | SNS topic, email, SMS, Lambda, webhooks |

---

## Outputs

| Output | Description |
|---|---|
| `task_definition_arn` | Full ARN including revision |
| `ecs_service_name` | ECS service name |
| `task_role_arn` | Task IAM role ARN |
| `task_exec_role_arn` | Execution IAM role ARN |
| `security_group_id` | Task security group ID |
| `target_group_arns` | Map of TG ARNs keyed by LB name |
| `listener_rule_arns` | Map of listener rule ARNs |
| `dns_record_fqdns` | Map of Route53 FQDNs |
| `cloudwatch_log_group_name` | CW log group name |
| `sns_topic_arn` | Alerts SNS topic ARN |

---

## Documentation

| Doc | Contents |
|---|---|
| [`docs/features.md`](./docs/features.md) | Feature deep-dives, IAM model, routing logic, troubleshooting |
| [`docs/logging.md`](./docs/logging.md) | FireLens config, same-account vs cross-account Kinesis |
| [`docs/variables.md`](./docs/variables.md) | Full variable reference with validation rules |
| [`docs/configuration.md`](./docs/configuration.md) | tfvars per environment (dev/staging/uat/prod) |
| [`docs/security-groups.md`](./docs/security-groups.md) | Security group rules guide |
| [`docs/entrypoint.md`](./docs/entrypoint.md) | Command & entrypoint override patterns |
| [`examples/README.md`](./examples/README.md) | Usage patterns for 6 common scenarios |

---

## Requirements

| Name | Version |
|---|---|
| terraform | >= 1.3 |
| aws | >= 5.0 |
| random | >= 3.0 |

---

## License

Apache 2.0 — see [LICENSE](../../LICENSE)
