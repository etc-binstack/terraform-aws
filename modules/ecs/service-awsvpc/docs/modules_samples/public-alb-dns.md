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
