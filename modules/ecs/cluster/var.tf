## =========================================
## variables: Common
## =========================================
variable "enable_module" {
  description = "Toggle to deploy or destroy all resources in this module"
  type        = bool
  default     = false
}

variable "environment" {
  description = "Deployment environment: development | staging | uat | production"
  type        = string
}

variable "cluster_name" {
  description = "Cluster identifier. Combined with environment to form: {environment}-{cluster_name}-cluster"
  type        = string
}

variable "tags" {
  description = "Tags applied to all taggable resources"
  type        = map(string)
  default     = {}
}

## =========================================
## Container Insights
## =========================================
variable "monitoring_settings" {
  description = "ECS cluster settings. Used to enable/configure CloudWatch Container Insights."
  type = list(object({
    name  = string
    value = string
  }))
  default = [
    {
      name  = "containerInsights"
      value = "disabled"
    }
  ]

  validation {
    condition = alltrue([
      for setting in var.monitoring_settings :
      setting.name == "containerInsights" ? contains(["enabled", "enhanced", "disabled"], setting.value) : true
    ])
    error_message = "containerInsights value must be 'enabled', 'enhanced', or 'disabled'."
  }

  validation {
    condition = alltrue([
      for setting in var.monitoring_settings :
      setting.name != null && setting.name != ""
    ])
    error_message = "Setting name cannot be null or empty."
  }

  validation {
    condition = alltrue([
      for setting in var.monitoring_settings :
      setting.value != null && setting.value != ""
    ])
    error_message = "Setting value cannot be null or empty."
  }
}

## =========================================
## Service Discovery (Cloud Map)
## =========================================
variable "namespace_configuration" {
  description = "Cloud Map private DNS namespace for ECS Service Connect"
  type = object({
    enabled            = bool
    create_new         = bool
    namespace_name     = string
    existing_namespace = optional(string)
    vpc_id             = string
  })
  default = {
    enabled            = false
    create_new         = true
    namespace_name     = null
    existing_namespace = null
    vpc_id             = null
  }

  validation {
    condition     = !(var.namespace_configuration.enabled == true && var.namespace_configuration.namespace_name == null && var.namespace_configuration.existing_namespace == null)
    error_message = "If namespace is enabled, either namespace_name or existing_namespace must be provided."
  }

  validation {
    condition     = !(var.namespace_configuration.enabled == true && (var.namespace_configuration.vpc_id == null || var.namespace_configuration.vpc_id == ""))
    error_message = "If namespace is enabled, vpc_id must not be null or empty."
  }

  validation {
    condition     = !(var.namespace_configuration.enabled == true && var.namespace_configuration.create_new == false && var.namespace_configuration.existing_namespace == null)
    error_message = "If namespace enabled and create_new is false, existing_namespace must be provided."
  }

  validation {
    condition     = !(var.namespace_configuration.enabled == true && var.namespace_configuration.create_new == true && var.namespace_configuration.namespace_name == null)
    error_message = "If namespace enabled and create_new is true, namespace_name must be provided."
  }
}

## =========================================
## Capacity Providers
## Supports: FARGATE, FARGATE_SPOT, EC2 (ASG)
## EC2 provider enables: awsvpc mode and bridge mode tasks
## =========================================
variable "capacity_providers" {
  description = "Capacity provider configuration. Enable Fargate, SPOT, and/or EC2 providers."
  type = object({

    ## Fargate — serverless, awsvpc only
    fargate = optional(object({
      enabled        = optional(bool, true)
      default_base   = optional(number, 0)   # minimum guaranteed tasks on this provider
      default_weight = optional(number, 1)   # relative share of new tasks
    }), { enabled = true })

    ## Fargate SPOT — up to 70% cheaper, can be interrupted (2-min SIGTERM)
    fargate_spot = optional(object({
      enabled        = optional(bool, false)
      default_base   = optional(number, 0)
      default_weight = optional(number, 0)
    }), { enabled = false })

    ## EC2 — required for: bridge mode, GPU instances, high-density packing
    ## Creates: launch template + ASG + ECS capacity provider
    ec2 = optional(object({
      enabled = optional(bool, false)

      ## Instance config
      instance_type = optional(string, "t3.medium")
      ## ami_id: null = auto-resolve to latest ECS-optimized Amazon Linux 2 AMI via SSM
      ami_id        = optional(string, null)
      key_name      = optional(string, null)

      ## User data appended to base ECS agent bootstrap
      ## Base user data always sets ECS_CLUSTER and ECS_ENABLE_TASK_ENI=true
      ## ECS_ENABLE_TASK_ENI=true supports both awsvpc and bridge mode tasks
      extra_user_data = optional(string, "")

      ## IAM — optional additional instance profile policies
      additional_iam_policy_arns = optional(list(string), [])

      ## ASG config
      min_size             = optional(number, 0)
      max_size             = optional(number, 5)
      desired_capacity     = optional(number, 1)
      vpc_zone_identifier  = optional(list(string), [])   # private subnet IDs

      ## Managed scaling — ECS adjusts EC2 count based on task placement demand
      managed_scaling_enabled        = optional(bool, true)
      managed_scaling_target         = optional(number, 80)   # % of EC2 capacity to use before scaling
      managed_draining_enabled       = optional(bool, true)   # drain tasks before instance termination
      instance_warmup_period         = optional(number, 300)  # seconds before new instance capacity is counted
      minimum_scaling_step_size      = optional(number, 1)
      maximum_scaling_step_size      = optional(number, 10)

      ## Capacity provider cluster defaults
      default_base   = optional(number, 0)
      default_weight = optional(number, 0)
    }), { enabled = false })
  })

  default = {
    fargate      = { enabled = true }
    fargate_spot = { enabled = false }
    ec2          = { enabled = false }
  }
}
