## =====================================
## Generate Random IDs
## =====================================
resource "random_id" "this" {
  count       = var.enable_module ? 1 : 0
  byte_length = var.random_id
}

## =====================================
## CHOOSE RANDOM ID (conditionally) 
## =====================================
locals {

  # CHOOSE RANDOM ID: Define a local variable to conditionally choose random ID or the provided value
  // random_id = var.enable_module && var.random_suffix != "" ? var.random_suffix : random_id.this[0].hex
  // random_id = var.enable_module ? (var.random_suffix != "" ? var.random_suffix : random_id.this[0].hex) : 0
  random_id = var.enable_module && var.random_suffix != "" ? var.random_suffix : (length(random_id.this) > 0 ? random_id.this[0].hex : "")
}


## =====================================
## onfigure VPC Network (conditionally) 
## =====================================
locals {
  ## Legacy support
  // network = var.vpc_config

  ## New config
  network       = var.network_configuration
  peering_rules = local.network.aditional_security_group_rules.vpcpeer_ingress_rule
  custom_rules  = local.network.aditional_security_group_rules.custom_ingress_rule
}

## =====================================
## TASK DEFINATION 
## =====================================
locals {
  # TASK DEFINATION: base variables
  task_definition = var.ecs_task_definition
  container       = local.task_definition.container_definitions

  # TASK DEFINATION: Configure Environment Variables, Secrets & Volumes
  environment = local.task_definition.configure_environment
  secrets     = local.task_definition.configure_secrets
  volume      = local.task_definition.configure_volume

  # TASK DEFINATION: Configure Logs (firelens/fluentbit)
  fluentbit = local.task_definition.configure_logs

  # TASK DEFINATION: Use host_port if explicitly defined, otherwise fall back to container_port
  host_port = local.container.host_port != null ? local.container.host_port : local.container.container_port

  # TASK DEFINATION: Health check block for container definition (optional) - only when enabled
  healthcheck_config = local.container.configure_healthcheck.enabled && local.container.configure_healthcheck != null ? {
    command     = local.container.configure_healthcheck.command
    interval    = local.container.configure_healthcheck.interval
    timeout     = local.container.configure_healthcheck.timeout
    retries     = local.container.configure_healthcheck.retries
    startPeriod = local.container.configure_healthcheck.startPeriod
  } : null

  # TASK DEFINATION: Command configuration (optional) - only when enabled
  command_config = local.container.configure_command.enabled && local.container.configure_command != null ? (
    jsonencode(local.container.configure_command.command)
  ) : null
  enable_command = local.container.configure_command.enabled

  # TASK DEFINATION: EntryPoint configuration (optional) - only when enabled
  entrypoint_config = local.container.configure_entrypoint.enabled && local.container.configure_entrypoint != null ? (
    jsonencode(local.container.configure_entrypoint.entrypoint)
  ) : null
  enable_entrypoint = local.container.configure_entrypoint.enabled
}


## =====================================
## ECS SERVICE CONFIGURE
## =====================================
locals {
  ecs_service           = var.configure_ecs_service
  launch_type           = local.ecs_service.launch_type
  service_connect       = local.ecs_service.service_connect
  scaling_capacity      = local.ecs_service.scaling_capacity
  cap_provider_strategy = local.ecs_service.capacity_provider_strategy
  task_compatibilities  = local.ecs_service.task_compatibilities

  # true  → use capacity_provider_strategy block, set launch_type = null on service
  # false → use launch_type string on service
  use_capacity_provider = length(local.cap_provider_strategy) > 0
}

## =====================================
## SCALING POLICIES
## =====================================
locals {
  scaling_policies  = var.scaling_policies
  cpu               = local.scaling_policies.cpu
  memory            = local.scaling_policies.memory
  target_tracking   = local.scaling_policies.target_tracking
  scheduled_actions = local.scaling_policies.scheduled_actions
}

## =====================================
## LOAD BALANCER MAP
## =====================================
locals {
  # Keyed map for for_each on TG, listener rules, DNS records
  lb_map = { for lb in var.configure_load_balancers : lb.name => lb }

  # Subset: only LBs with routing enabled and a real listener ARN
  lb_with_routing = {
    for name, lb in local.lb_map : name => lb
    if lb.listener_rule.enable_routing && lb.listener_rule.listener_arn != ""
  }

  # Subset: only LBs with DNS enabled
  lb_with_dns = {
    for name, lb in local.lb_map : name => lb
    if lb.dns.enabled
  }
}

## Notification/Alerts Configuration (configure_notification)
locals {
  alerts = var.configure_alerts
  enabled_alerts = local.alerts.enabled_alerts != null ? local.alerts.enabled_alerts : {
    cpu_high    = false
    cpu_low     = false
    memory_high = false
    memory_low  = false
  }
}


## =====================================
## CONFIGURE LOGS (FireLens / Fluent Bit)
## =====================================
locals {
  ## Index prefix for Fluent Bit ENVIRONMENT env var
  ## Falls back to var.environment when log_index_prefix not set
  log_index_prefix = (
    local.fluentbit.log_index_prefix != null && local.fluentbit.log_index_prefix != ""
    ? local.fluentbit.log_index_prefix
    : var.environment
  )

  ## Cross-account role ARN (null = same-account, use task role directly)
  kinesis_cross_account_role_arn = local.fluentbit.kinesis_cross_account_role_arn

  ## S3 ARN for custom Fluent Bit config (null = use AWS default config)
  fluentbit_config_s3_arn = local.fluentbit.fluentbit_config_s3_arn

  ## Fluent Bit container environment variables
  ## ECS_TASK_ARN and ECS_TASK_DEFINITION intentionally omitted:
  ## these are injected automatically via enable-ecs-log-metadata in firelensConfiguration
  set_fluentbit_environment = [
    {
      "name" : "KINESIS_REGION",
      "value" : var.aws_region    # uses deployment region, not hardcoded
    },
    {
      "name" : "STREAM",
      "value" : local.fluentbit.kinesis_stream_name
    },
    {
      "name" : "ECS_CLUSTER",
      "value" : local.ecs_service.ecs_cluster_name
    },
    {
      "name" : "ECS_TASK_NAME",
      "value" : "${var.environment}-${var.ecs_cluster_prefix}-${local.task_definition.task_name}"
    },
    {
      "name" : "ECS_SERVICE_NAME",
      "value" : "${var.environment}-${var.ecs_cluster_prefix}-${local.task_definition.task_name}"
    },
    {
      "name" : "ENVIRONMENT",
      "value" : local.log_index_prefix
    },
    {
      # Empty string when same-account; role ARN when cross-account
      # Fluent Bit kinesis_streams plugin uses this for sts:AssumeRole
      "name" : "KINESIS_ROLE_ARN",
      "value" : local.kinesis_cross_account_role_arn != null ? local.kinesis_cross_account_role_arn : ""
    }
  ]

  ## Secrets passed to Fluent Bit container
  ## Empty by default — static keys are legacy pattern (see docs/LOGS_CONFIG.md)
  ## Use kinesis_cross_account_role_arn instead of static keys for cross-account
  set_fluentbit_secrets = local.fluentbit.set_fluentbit_secrets
}