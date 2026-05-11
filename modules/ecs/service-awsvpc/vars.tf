## =========================================
## variables: Env Basic
## =========================================
variable "enable_module" {
  description = "Whether to deploy the module or not"
  type        = bool
  default     = false
}

variable "enable_exec_command" {
  description = <<-EOT
    Enable ECS Exec — SSM-based shell access into running containers.
    Off by default. Enable for dev/staging debugging. Production: only with explicit security approval.
    Requires SSM agent in container image and SSM VPC endpoint or NAT Gateway.
    When enabled: task role gets ssmmessages:* permissions automatically.
  EOT
  type    = bool
  default = false
}

variable "environment" {
  type = string
}

variable "common_tags" {
  type    = map(string)
  default = {}
}

variable "random_id" {
  description = "Byte length for random ID"
  type        = number
  default     = 3
}

variable "random_suffix" {
  description = "Optional random ID to use in role name"
  type        = string
  default     = ""
}

variable "ecs_cluster_prefix" {
  description = "Prefix to be used for naming the ECS cluster and associated resources"
  type        = string
  default     = "demo-cluster"
}

variable "aws_region" {
  description = "AWS region where ECS resources will be deployed"
  type        = string
  default     = "us-east-1"
}

## =========================================
## IAM Role Policy
## =========================================
variable "aws_account_id" {
  type        = string
  description = "AWS account ID where resources will be created"

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "AWS account ID must be a 12-digit number."
  }
}

variable "aws_cross_account_id" {
  type        = string
  default     = null
  description = "AWS cross-account ID for cross-account access or resource sharing"

  validation {
    condition     = var.aws_cross_account_id == null || can(regex("^[0-9]{12}$", var.aws_cross_account_id))
    error_message = "AWS cross-account ID must be a 12-digit number."
  }
}

## =========================================
## IAM Secret Scope (optional, opt-in)
## =========================================
variable "secret_path_prefix" {
  type        = string
  default     = null
  description = <<-EOT
    Scope Secrets Manager and SSM access to this path prefix in the same account.
    null (default) = wildcard access — backward compatible, no behaviour change.
    Recommended value: "$${environment}/$${ecs_cluster_prefix}"
    Example: "production/platform" → allows secret:production/platform/*
  EOT
}

variable "cross_account_secret_path_prefix" {
  type        = string
  default     = null
  description = <<-EOT
    Scope cross-account Secrets Manager access to this path prefix.
    null (default) = wildcard access. Only applies when aws_cross_account_id is set.
    Recommended value: "$${environment}/$${ecs_cluster_prefix}"
  EOT
}

## =========================================
## ECS taskdefination (configure)
## =========================================
variable "ecs_task_definition" {
  description = "Configuration for ECS task definition including ports, resources, environment, secrets, and EFS settings."
  type = object({
    task_name = string
    container_definitions = object({
      container_image = string
      container_port  = number
      host_port       = optional(number)
      fargate_cpu     = number
      fargate_memory  = number

      # Seconds ECS waits after SIGTERM before sending SIGKILL.
      # Default 30s. Fargate max 120s. Increase for workers, JVM, gRPC streams.
      stop_timeout = optional(number, 30)

      configure_healthcheck = optional(object({
        enabled     = optional(bool, false)
        command     = list(string) # <-- this is where you provide the command
        interval    = optional(number, 30)
        timeout     = optional(number, 5)
        retries     = optional(number, 3)
        startPeriod = optional(number, 0)
      }))
      # ADD THESE NEW FIELDS:
      configure_command = optional(object({
        enabled = optional(bool, false)
        command = optional(list(string), [])
      }), {
        enabled = false
        command = []
      })

      configure_entrypoint = optional(object({
        enabled    = optional(bool, false)
        entrypoint = optional(list(string), [])
      }), {
        enabled    = false
        entrypoint = []
      })      
    })

    configure_secrets = optional(object({
      enable_secrets = optional(bool, false)
      set_secrets = optional(list(object({
        name      = string
        valueFrom = string
      })), [])
      }), {
      enable_secrets = false
      set_secrets    = []
    })

    configure_environment = optional(object({
      enable_environment = optional(bool, false)
      set_environment = optional(list(object({
        name  = string
        value = string
      })), [])
      }), {
      enable_environment = false
      set_environment    = []
    })

    configure_volume = optional(object({
      enable_efs = optional(bool, false)
      set_efs_volumes = optional(list(object({
        host_path = string
        name      = string
        efs_volume_configuration = list(object({
          file_system_id = string
          authorization_config = list(object({
            access_point_id = string
            iam             = string
          }))
        }))
      })), [])
      set_mount_points = optional(list(object({
        sourceVolume  = string
        containerPath = string
      })), [])
      }), {
      enable_efs       = false
      set_efs_volumes  = []
      set_mount_points = []
    })

    ## FireLens / Fluent Bit logging (optional)
    ## See docs/LOGS_CONFIG.md for same-account vs cross-account architecture
    configure_logs = optional(object({
      enable_fluentbit = optional(bool, false)
      fluentbit_image  = optional(string, "amazon/aws-for-fluent-bit:stable")

      ## Kinesis stream name in target account (same or central logs account)
      kinesis_stream_name = optional(string, "")

      ## Index prefix used as ENVIRONMENT env var in Fluent Bit (e.g. "myproject-production")
      ## Renamed from logstash_environment — no Logstash dependency
      log_index_prefix = optional(string, "")

      ## Cross-account Kinesis: ARN of writer role in central logs account
      ## null  → Fluent Bit uses ECS task role directly (same-account)
      ## "arn" → Fluent Bit assumes this role (cross-account, no static keys)
      kinesis_cross_account_role_arn = optional(string, null)

      ## S3 ARN of custom fluent-bit.conf
      ## null  → AWS default Fluent Bit config (basic, no PII filtering)
      ## "arn" → S3-backed config (PII filtering, multi-stream routing, JSON parsing)
      fluentbit_config_s3_arn = optional(string, null)

      ## Legacy: static AWS credentials for Kinesis auth (avoid — use IAM role instead)
      ## Leave empty [] when using kinesis_cross_account_role_arn or same-account task role
      set_fluentbit_secrets = optional(list(object({
        name      = string
        valueFrom = string
      })), [])

    }), { enable_fluentbit = false })
    ## Add more variables here as needed
  })
}

## =========================================
## VPC Mapper (Enable Access from Peering)
## =========================================

## ----------- Legacy Config -------------
# variable "vpc_config" {
#   description = "Configuration for VPC settings and optional peering"
#   type = object({
#     vpc_id               = string
#     vpc_subnet_ids       = list(string)
#     vpc_cidr             = string
#     enable_peering_route = optional(bool, false)      # Toggle to enable/disable VPC peering
#     peering_cidrs        = optional(list(string), []) # List of CIDR blocks for VPC peering connections
#   })
#   default = {
#     vpc_id               = null
#     vpc_subnet_ids       = []
#     vpc_cidr             = null
#     enable_peering_route = false
#     peering_cidrs        = []
#   }
# }

## ----------- New Config -------------
## Configure Security Group
# variable "custom_ingress_rule" {
#   description = "Custom ingress rule configuration"
#   type = object({
#     enabled       = optional(bool, false)
#     create_rules  = optional(map(object({
#       from_port   = number
#       to_port     = number
#       protocol    = string
#       cidr_blocks = list(string)
#       description = string
#     })), {})
#   })
#   default = {
#     enabled      = false
#     create_rules = {}
#   }
# }

## ----------- Combined Config -------------
variable "network_configuration" {
  description = "Configuration for VPC settings and optional peering"
  type = object({
    vpc_id         = string
    vpc_subnet_ids = list(string)
    vpc_cidr       = string

    aditional_security_group_rules = optional(object({
      vpcpeer_ingress_rule = optional(object({
        peering_cidrs = optional(list(string), [])
      }), {})

      custom_ingress_rule = optional(object({
        create_rules = optional(map(object({
          from_port   = optional(number)
          to_port     = optional(number)
          protocol    = optional(string)
          cidr_blocks = optional(list(string), [])
          description = optional(string)
        })), {})
      }), {})
    }), {})
  })

  default = {
    vpc_id         = null
    vpc_subnet_ids = []
    vpc_cidr       = null

    aditional_security_group_rules = {
      vpcpeer_ingress_rule = {
        peering_cidrs = []
      }
      custom_ingress_rule = {
        create_rules = {}
      }
    }
  }
}

## =========================================
## Load Balancer Configuration (ALB / NLB)
## Replaces separate configure_alb + configure_dns.
## Pass a list — zero (worker), one (standard), or many (multi-LB) entries.
## Each entry creates: one target group + one listener rule + optional Route53 record.
## =========================================
variable "configure_load_balancers" {
  description = "List of load balancer attachments. Each entry = one TG + listener rule + optional DNS."
  type = list(object({
    name           = string  # unique key used in resource names and for_each (e.g. "public-alb")
    type           = string  # "alb" | "nlb"
    container_port = number  # which container port this LB routes to

    target_group = optional(object({
      target_type = optional(string, "ip")    # "ip" required for Fargate awsvpc mode
      protocol    = optional(string, "HTTP")  # ALB: HTTP|HTTPS  NLB: TCP|TLS|UDP|TCP_UDP

      health_check = optional(object({
        path                = optional(string, "/")
        protocol            = optional(string, "HTTP")
        matcher             = optional(string, "200")
        interval            = optional(number, 30)
        timeout             = optional(number, 5)
        healthy_threshold   = optional(number, 3)
        unhealthy_threshold = optional(number, 2)
      }), {})

      deregistration_delay          = optional(number, 300)
      slow_start                    = optional(number, 0)
      load_balancing_algorithm_type = optional(string, "round_robin") # round_robin | least_outstanding_requests | weighted_random
    }), {})

    listener_rule = optional(object({
      enable_routing     = optional(bool, true)
      listener_arn       = string                          # ARN of existing ALB/NLB listener
      routing_type       = optional(string, "simple")      # "simple" | "complex"
      routing_method     = optional(string, "host_header") # "host_header" | "path_pattern" | "mixed_route"
      host_header_value  = optional(list(string), [])
      path_pattern_value = optional(string, "/*")
      # Explicit listener rule priority (1-50000).
      # null = random (100-900). Set explicitly when multiple services share
      # the same ALB listener to prevent DuplicatePriority collision on apply.
      priority           = optional(number, null)
    }), { listener_arn = "" })

    dns = optional(object({
      enabled        = optional(bool, false)
      hosted_zone_id = optional(string, "")  # Route53 Hosted Zone ID
      lb_dns_name    = optional(string, "")  # LB DNS name (from LB resource)
      lb_zone_id     = optional(string, "")  # LB hosted zone ID (from LB resource)
    }), {})
  }))

  default = []

  validation {
    condition = alltrue([
      for lb in var.configure_load_balancers : contains(["alb", "nlb"], lb.type)
    ])
    error_message = "Each load balancer type must be 'alb' or 'nlb'."
  }

  validation {
    condition = alltrue([
      for lb in var.configure_load_balancers : contains(["simple", "complex"], lb.listener_rule.routing_type)
    ])
    error_message = "listener_rule.routing_type must be 'simple' or 'complex'."
  }

  validation {
    condition = alltrue([
      for lb in var.configure_load_balancers : contains(["host_header", "path_pattern", "mixed_route"], lb.listener_rule.routing_method)
    ])
    error_message = "listener_rule.routing_method must be 'host_header', 'path_pattern', or 'mixed_route'."
  }

  validation {
    condition = alltrue([
      for lb in var.configure_load_balancers :
      lb.listener_rule.priority == null || (lb.listener_rule.priority >= 1 && lb.listener_rule.priority <= 50000)
    ])
    error_message = "listener_rule.priority must be between 1 and 50000 (AWS ALB limit), or null for random."
  }
}

## =========================================
## ECS Service (configure)
## =========================================
variable "configure_ecs_service" {
  description = "ECS service configuration: launch type, capacity providers, scaling, service connect."
  type = object({
    ecs_cluster_id   = string
    ecs_cluster_name = string

    ## Used when capacity_provider_strategy is empty (simple path)
    launch_type = optional(string, "FARGATE") # "FARGATE" | "EC2" | "EXTERNAL"

    ## When set, overrides launch_type — mutually exclusive in AWS API
    ## Supports: "FARGATE" | "FARGATE_SPOT" | EC2 ASG capacity provider name
    capacity_provider_strategy = optional(list(object({
      capacity_provider = string
      weight            = number
      base              = optional(number, 0)
    })), [])

    ## Controls aws_ecs_task_definition requires_compatibilities
    ## Defaults to ["FARGATE"]; set ["EC2"] or ["FARGATE","EC2"] when using EC2 launch type
    task_compatibilities = optional(list(string), ["FARGATE"])

    scaling_capacity = object({
      desired_count = optional(number, 0)
      min_capacity  = optional(number, 0)
      max_capacity  = optional(number, 0)
    })

    service_connect = optional(object({
      enabled        = optional(bool, false)
      namespace_name = optional(string, null)
    }), {})

    health_check_grace_period_seconds = optional(number, 0)
  })

  validation {
    condition     = contains(["FARGATE", "EC2", "EXTERNAL"], var.configure_ecs_service.launch_type)
    error_message = "launch_type must be FARGATE, EC2, or EXTERNAL."
  }
}

## =========================================
## Autoscaling Values
## =========================================
variable "scaling_policies" {
  description = "ECS Auto Scaling: step scaling (CPU/Memory), target tracking, and scheduled actions."
  type = object({
    enabled = bool

    ## --- Step Scaling: CPU ---
    cpu = object({
      scale_up_enabled   = bool
      scale_down_enabled = bool
      scale_up = object({
        threshold          = number
        evaluation_periods = number
        period             = number
        cooldown           = number
        lower_bound        = number
        scale_by           = number
      })
      scale_down = object({
        threshold          = number
        evaluation_periods = number
        period             = number
        cooldown           = number
        upper_bound        = number
        scale_by           = number
      })
    })

    ## --- Step Scaling: Memory ---
    memory = object({
      scale_up_enabled   = bool
      scale_down_enabled = bool
      scale_up = object({
        threshold          = number
        evaluation_periods = number
        period             = number
        cooldown           = number
        lower_bound        = number
        scale_by           = number
      })
      scale_down = object({
        threshold          = number
        evaluation_periods = number
        period             = number
        cooldown           = number
        upper_bound        = number
        scale_by           = number
      })
    })

    ## --- Target Tracking Scaling (optional) ---
    ## AWS auto-manages scale up/down. Just set the target metric value.
    ## metric options:
    ##   "ECSServiceAverageCPUUtilization"    -> keep CPU at target_value %
    ##   "ECSServiceAverageMemoryUtilization" -> keep Memory at target_value %
    ##   "ALBRequestCountPerTarget"           -> keep RPS per task at target_value
    target_tracking = optional(object({
      enabled                     = optional(bool, false)
      metric                      = optional(string, "ECSServiceAverageCPUUtilization")
      target_value                = optional(number, 60)
      scale_in_cooldown           = optional(number, 300)
      scale_out_cooldown          = optional(number, 60)
      disable_scale_in            = optional(bool, false)
      alb_target_group_arn_suffix = optional(string, "") # required when metric = "ALBRequestCountPerTarget"
    }), { enabled = false })

    ## --- Scheduled Scaling (optional) ---
    ## Override min/max/desired at specific times (business hours, off-peak, pre-event warmup)
    ## schedule format:  one-time  -> "at(2026-12-31T23:59:00)"
    ## recurrence format: cron     -> "cron(0 8 * * MON-FRI)"   (UTC by default)
    scheduled_actions = optional(list(object({
      name         = string
      min_capacity = optional(number)
      max_capacity = optional(number)
      desired      = optional(number)
      schedule     = optional(string) # one-time: "at(...)"
      recurrence   = optional(string) # cron: "cron(...)"
      timezone     = optional(string, "UTC")
    })), [])
  })

  default = {
    enabled = true

    cpu = {
      scale_up_enabled   = true
      scale_down_enabled = true
      scale_up = {
        threshold          = 70 // The alarm triggers if CPU utilization is 70% or greater for 2 consecutive periods.
        evaluation_periods = 3  // The condition must be met for 2 consecutive periods for the alarm to trigger.
        period             = 60 // Each evaluation period is 60 seconds (1 minute) long.
        cooldown           = 60 // Wait 30 seconds before another scaling activity can occur after this one.
        lower_bound        = 0  // This rule applies when the metric is less than or equal to 0.
        scale_by           = 1  //	Decrease the desired count by 1 (i.e., scale Up by 1 task).
      }
      scale_down = {
        threshold          = 2   // The alarm triggers if CPU utilization is 5% or lower for 2 consecutive periods.
        evaluation_periods = 5   // The condition must be met for 2 consecutive periods for the alarm to trigger.
        period             = 60  // Each evaluation period is 60 seconds (1 minute) long.
        cooldown           = 300 // Wait 30 seconds before another scaling activity can occur after this one.
        upper_bound        = 0   // This rule applies when the metric is less than or equal to 0.
        scale_by           = -1  //	Decrease the desired count by 1 (i.e., scale down by 1 task).
      }
    }

    memory = {
      scale_up_enabled   = true
      scale_down_enabled = true
      scale_up = {
        threshold          = 80 // The alarm triggers if Memory utilization is 80% or greater for 2 consecutive periods.
        evaluation_periods = 3  // The condition must be met for 2 consecutive periods for the alarm to trigger.
        period             = 60 // Each evaluation period is 60 seconds (1 minute) long.
        cooldown           = 60 // Wait 30 seconds before another scaling activity can occur after this one.
        lower_bound        = 0  // This rule applies when the metric is less than or equal to 0.
        scale_by           = 1  //	Decrease the desired count by 1 (i.e., scale Up by 1 task).
      }
      scale_down = {
        threshold          = 3   // The alarm triggers if Memory utilization is 5% or lower for 2 consecutive periods.
        evaluation_periods = 5   // The condition must be met for 2 consecutive periods for the alarm to trigger.
        period             = 60  // Each evaluation period is 60 seconds (1 minute) long.
        cooldown           = 300 // Wait 30 seconds before another scaling activity can occur after this one.
        upper_bound        = 0   // This rule applies when the metric is less than or equal to 0.
        scale_by           = -1  //	Decrease the desired count by 1 (i.e., scale down by 1 task).
      }
    }
  }

  validation {
    condition = (
      var.scaling_policies.cpu.scale_up.cooldown >= 0 &&
      var.scaling_policies.cpu.scale_down.cooldown >= 0 &&
      var.scaling_policies.memory.scale_up.cooldown >= 0 &&
      var.scaling_policies.memory.scale_down.cooldown >= 0
    )
    error_message = "Cooldown (second) values must be zero or positive."
  }

  validation {
    condition = (
      var.scaling_policies.cpu.scale_up.threshold >= 0 &&
      var.scaling_policies.cpu.scale_down.threshold >= 0 &&
      var.scaling_policies.memory.scale_up.threshold >= 0 &&
      var.scaling_policies.memory.scale_down.threshold >= 0
    )
    error_message = "Thresholds (%) must be non-negative values."
  }

  validation {
    condition = (
      var.scaling_policies.cpu.scale_up.evaluation_periods > 0 &&
      var.scaling_policies.cpu.scale_down.evaluation_periods > 0 &&
      var.scaling_policies.memory.scale_up.evaluation_periods > 0 &&
      var.scaling_policies.memory.scale_down.evaluation_periods > 0
    )
    error_message = "Evaluation periods must be greater than 0."
  }

  validation {
    condition = (
      var.scaling_policies.cpu.scale_up.scale_by != 0 &&
      var.scaling_policies.cpu.scale_down.scale_by != 0 &&
      var.scaling_policies.memory.scale_up.scale_by != 0 &&
      var.scaling_policies.memory.scale_down.scale_by != 0
    )
    error_message = "Scale-by values must not be zero."
  }
}


# Notification Configuration (configure_notification)
variable "configure_alerts" {
  description = "Configuration for alarm notifications (SNS, Email, SMS, Webhooks)"
  type = object({

    # SNS Configuration
    enabled            = optional(bool, false)
    topic_name         = optional(string, null)
    email_endpoints    = optional(list(string), [])
    sms_endpoints      = optional(list(string), [])
    lambda_arns        = optional(list(string), [])
    slack_webhook_url  = optional(string)
    teams_webhook_url  = optional(string)
    custom_webhook_url = optional(string)

    # Alert toggles - by default enabled for high, disabled for low
    enabled_alerts = optional(object({
      cpu_high    = optional(bool, false)
      cpu_low     = optional(bool, false)
      memory_high = optional(bool, false)
      memory_low  = optional(bool, false)
    }))
  })
  default = {
    # SNS Configuration with defaults
    enabled            = false
    topic_name         = "container-alerts"
    email_endpoints    = []
    sms_endpoints      = []
    lambda_arns        = []
    slack_webhook_url  = null
    teams_webhook_url  = null
    custom_webhook_url = null

    # Alert toggles
    enabled_alerts = {
      cpu_high    = false
      cpu_low     = false
      memory_high = false
      memory_low  = false
    }
  }

  # validation {
  #   condition = var.configure_alerts.enabled == false || (
  #     length(var.configure_alerts.email_endpoints) > 0 ||
  #     length(var.configure_alerts.sms_endpoints) > 0 ||
  #     length(var.configure_alerts.lambda_arns) > 0 ||
  #     var.configure_alerts.slack_webhook_url != null ||
  #     var.configure_alerts.teams_webhook_url != null ||
  #     var.configure_alerts.custom_webhook_url != null
  #   )
  #   error_message = "If notifications are enabled, at least one notification method must be configured."
  # }

  validation {
    condition = alltrue([
      for email in var.configure_alerts.email_endpoints :
      can(regex("^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$", email))
    ])
    error_message = "All email addresses must be valid email format."
  }

  validation {
    condition = alltrue([
      for phone in var.configure_alerts.sms_endpoints :
      can(regex("^\\+[1-9]\\d{1,14}$", phone))
    ])
    error_message = "All phone numbers must be in E.164 format (e.g., +1234567890)."
  }
}


