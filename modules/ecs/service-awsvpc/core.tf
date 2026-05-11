## ==================================================
## ECS: Tasks Configuration
## templatefile() replaces deprecated data "template_file" resource (Terraform >= 0.12)
## ==================================================

resource "aws_ecs_task_definition" "task" {
  count                    = var.enable_module ? 1 : 0
  family                   = "${var.environment}-${var.ecs_cluster_prefix}-${local.task_definition.task_name}"
  execution_role_arn       = aws_iam_role.task_exec_role[0].arn
  task_role_arn            = aws_iam_role.task_role[0].arn
  network_mode             = "awsvpc"
  requires_compatibilities = local.task_compatibilities
  cpu                      = local.container.fargate_cpu
  memory                   = local.container.fargate_memory

  dynamic "volume" {
    for_each = local.volume.enable_efs ? local.volume.set_efs_volumes : []
    content {
      name                = volume.value.name
      configure_at_launch = try(volume.value.configure_at_launch, false)
      # host_path = try(volume.value.host_path, null)

      dynamic "efs_volume_configuration" {
        for_each = volume.value.efs_volume_configuration

        content {
          file_system_id     = efs_volume_configuration.value.file_system_id
          transit_encryption = try(efs_volume_configuration.value.transit_encryption, "ENABLED")

          dynamic "authorization_config" {
            for_each = efs_volume_configuration.value.authorization_config

            content {
              access_point_id = try(authorization_config.value.access_point_id, null)
              iam             = try(authorization_config.value.iam, null)
            }
          }
        }
      }
    }
  }

  container_definitions = jsonencode(
    flatten([
      jsondecode(templatefile("${path.module}/templates/ecs_task.json.tpl", {
        environment        = var.environment
        ecs_cluster_prefix = var.ecs_cluster_prefix
        task_name          = local.task_definition.task_name
        container_image    = local.container.container_image
        fargate_cpu        = local.container.fargate_cpu
        fargate_memory     = local.container.fargate_memory
        aws_region         = var.aws_region
        container_port     = local.container.container_port
        host_port          = local.host_port
        enable_healthcheck = local.container.configure_healthcheck.enabled
        healthcheck_config = local.healthcheck_config != null ? jsonencode(local.healthcheck_config) : "null"
        enable_secrets     = local.secrets.enable_secrets
        set_secrets        = jsonencode(local.secrets.set_secrets)
        enable_environment = local.environment.enable_environment
        set_environment    = jsonencode(local.environment.set_environment)
        enable_efs         = local.volume.enable_efs
        set_efs_volumes    = jsonencode(local.volume.set_efs_volumes)
        set_mount_points   = jsonencode(local.volume.set_mount_points)
        stop_timeout       = local.container.stop_timeout
        enable_fluentbit   = local.fluentbit.enable_fluentbit
        enable_command     = local.enable_command
        command_config     = local.command_config != null ? local.command_config : "null"
        enable_entrypoint  = local.enable_entrypoint
        entrypoint_config  = local.entrypoint_config != null ? local.entrypoint_config : "null"
      })),
      local.fluentbit.enable_fluentbit ? jsondecode(templatefile("${path.module}/templates/ecs_task_fluentbit.json.tpl", {
        environment               = var.environment
        ecs_cluster_prefix        = var.ecs_cluster_prefix
        task_name                 = local.task_definition.task_name
        fluentbit_image           = local.fluentbit.fluentbit_image
        aws_region                = var.aws_region
        set_fluentbit_environment = jsonencode(local.set_fluentbit_environment)
        set_fluentbit_secrets     = jsonencode(local.set_fluentbit_secrets)
        fluentbit_config_s3_arn   = local.fluentbit_config_s3_arn != null ? local.fluentbit_config_s3_arn : ""
      })) : []
    ])
  )
}


#####################################################
## ECS: Service configuration
#####################################################
resource "aws_ecs_service" "service" {
  count           = var.enable_module ? 1 : 0
  name            = "${var.environment}-${var.ecs_cluster_prefix}-${local.task_definition.task_name}"
  cluster         = local.ecs_service.ecs_cluster_id
  task_definition = aws_ecs_task_definition.task[0].arn
  desired_count   = local.scaling_capacity.desired_count

  # launch_type and capacity_provider_strategy are mutually exclusive in AWS.
  # When capacity_provider_strategy list is non-empty, set launch_type = null.
  launch_type = local.use_capacity_provider ? null : local.launch_type

  dynamic "capacity_provider_strategy" {
    for_each = local.use_capacity_provider ? local.cap_provider_strategy : []
    content {
      capacity_provider = capacity_provider_strategy.value.capacity_provider
      weight            = capacity_provider_strategy.value.weight
      base              = capacity_provider_strategy.value.base
    }
  }

  health_check_grace_period_seconds = local.ecs_service.health_check_grace_period_seconds

  # Auto-rollback on deployment failure — stops infinite restart loops on bad deploys.
  # Always enabled. rollback = true returns service to last known-good task definition.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # Copies tags from task definition to running tasks.
  # Required for cost allocation, CloudWatch filtering, and tag-based IAM conditions.
  propagate_tags = "TASK_DEFINITION"

  # ECS Exec — SSM shell into running containers for debugging.
  # Off by default. Set enable_exec_command = true to enable.
  enable_execute_command = var.enable_exec_command

  network_configuration {
    security_groups  = [aws_security_group.sgp[0].id]
    subnets          = local.network.vpc_subnet_ids
    assign_public_ip = false
  }

  # Dynamic load_balancer blocks — one per configure_load_balancers entry
  # Zero entries = no load_balancer block (worker/background task pattern)
  dynamic "load_balancer" {
    for_each = var.enable_module ? local.lb_map : {}
    content {
      target_group_arn = aws_lb_target_group.tg[load_balancer.key].arn
      container_name   = "${var.environment}-${var.ecs_cluster_prefix}-${local.task_definition.task_name}"
      container_port   = load_balancer.value.container_port
    }
  }

  dynamic "service_connect_configuration" {
    for_each = local.service_connect.enabled ? [1] : []
    content {
      enabled   = true
      namespace = local.service_connect.namespace_name
      service {
        client_alias {
          dns_name = "${local.task_definition.task_name}.${local.service_connect.namespace_name}"
          port     = local.host_port
        }
        discovery_name = local.task_definition.task_name
        port_name      = local.task_definition.task_name
      }
    }
  }

  depends_on = [
    aws_iam_role.task_role,
    aws_iam_role.task_exec_role
  ]
}

#####################################################
## ECS: Auto-Scaling Fargate Tasks
#####################################################
resource "aws_appautoscaling_target" "scale_target" {
  count              = var.enable_module && local.scaling_policies.enabled ? 1 : 0
  service_namespace  = "ecs"
  resource_id        = "service/${local.ecs_service.ecs_cluster_name}/${aws_ecs_service.service[0].name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = local.scaling_capacity.min_capacity
  max_capacity       = local.scaling_capacity.max_capacity
}

##------------------------
## Scaling: CPUUtilization
##------------------------

## Scale capacity UP
resource "aws_appautoscaling_policy" "cpu_up" {
  count              = var.enable_module && local.scaling_policies.enabled && local.cpu.scale_up_enabled ? 1 : 0
  name               = "${var.environment}_${var.ecs_cluster_prefix}_${local.task_definition.task_name}_cpu_scale_up"
  service_namespace  = "ecs"
  resource_id        = "service/${local.ecs_service.ecs_cluster_name}/${aws_ecs_service.service[0].name}"
  scalable_dimension = "ecs:service:DesiredCount"

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = local.cpu.scale_up.cooldown
    metric_aggregation_type = "Maximum"

    step_adjustment {
      metric_interval_lower_bound = local.cpu.scale_up.lower_bound
      scaling_adjustment          = local.cpu.scale_up.scale_by
    }
  }
  depends_on = [aws_appautoscaling_target.scale_target]
}

# Scale capacity DOWN
resource "aws_appautoscaling_policy" "cpu_down" {
  count              = var.enable_module && local.scaling_policies.enabled && local.cpu.scale_down_enabled ? 1 : 0
  name               = "${var.environment}_${var.ecs_cluster_prefix}_${local.task_definition.task_name}_cpu_scale_down"
  service_namespace  = "ecs"
  resource_id        = "service/${local.ecs_service.ecs_cluster_name}/${aws_ecs_service.service[0].name}"
  scalable_dimension = "ecs:service:DesiredCount"

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = local.cpu.scale_down.cooldown
    metric_aggregation_type = "Maximum"

    step_adjustment {
      metric_interval_upper_bound = local.cpu.scale_down.upper_bound
      scaling_adjustment          = local.cpu.scale_down.scale_by
    }
  }
  depends_on = [aws_appautoscaling_target.scale_target]
}

# CloudWatch alarm triggers Scaling UP policy
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  count               = var.enable_module && local.scaling_policies.enabled && local.cpu.scale_up_enabled ? 1 : 0
  alarm_name          = "${var.environment}_${var.ecs_cluster_prefix}_${local.task_definition.task_name}_cpu_utilization_high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = local.cpu.scale_up.evaluation_periods
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = local.cpu.scale_up.period
  statistic           = "Average"
  threshold           = local.cpu.scale_up.threshold
  alarm_description   = "ECS Service CPU utilization is too high - scaling up tasks"

  dimensions = {
    ClusterName = local.ecs_service.ecs_cluster_name
    ServiceName = aws_ecs_service.service[0].name
  }

  # alarm_actions = [aws_appautoscaling_policy.cpu_up[0].arn] // without sns alerts

  # Combine autoscaling action with SNS alerts (if enabled)
  alarm_actions = compact([
    aws_appautoscaling_policy.cpu_up[0].arn,
    local.alerts.enabled && local.enabled_alerts.cpu_high ? aws_sns_topic.alerts[0].arn : null
  ])

  # Also send alerts when alarm resolves
  ok_actions = local.alerts.enabled && local.enabled_alerts.cpu_high ? [aws_sns_topic.alerts[0].arn] : []

  tags = merge(
    var.common_tags,
    {
      Component  = "alarm_metric_cpu_utilization_high"
      AlertLevel = "HIGH"
      MetricType = "CPU"
    }
  )
}

# CloudWatch alarm triggers Scaling DOWN policy
resource "aws_cloudwatch_metric_alarm" "cpu_low" {
  count               = var.enable_module && local.scaling_policies.enabled && local.cpu.scale_down_enabled ? 1 : 0
  alarm_name          = "${var.environment}_${var.ecs_cluster_prefix}_${local.task_definition.task_name}_cpu_utilization_low"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = local.cpu.scale_down.evaluation_periods
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = local.cpu.scale_down.period
  statistic           = "Average"
  threshold           = local.cpu.scale_down.threshold
  alarm_description   = "ECS Service CPU utilization is low - scaling down tasks"

  dimensions = {
    ClusterName = local.ecs_service.ecs_cluster_name
    ServiceName = aws_ecs_service.service[0].name
  }

  # alarm_actions = [aws_appautoscaling_policy.cpu_down[0].arn] // without sns alerts

  # Combine autoscaling action with SNS alerts (if enabled for low alerts)
  alarm_actions = compact([
    aws_appautoscaling_policy.cpu_down[0].arn,
    local.alerts.enabled && local.enabled_alerts.cpu_low ? aws_sns_topic.alerts[0].arn : null
  ])

  # Send alerts when alarm resolves
  ok_actions = local.alerts.enabled && local.enabled_alerts.cpu_low ? [aws_sns_topic.alerts[0].arn] : []

  tags = merge(
    var.common_tags,
    {
      Component  = "alarm_metric_cpu_utilization_low"
      AlertLevel = "LOW"
      MetricType = "CPU"
    }
  )
}

##---------------------------
## Scaling: MemoryUtilization
##---------------------------
# Automatically scale capacity UP by one
resource "aws_appautoscaling_policy" "mem_up" {
  count              = var.enable_module && local.scaling_policies.enabled && local.memory.scale_up_enabled ? 1 : 0
  name               = "${var.environment}_${var.ecs_cluster_prefix}_${local.task_definition.task_name}_mem_scale_up"
  service_namespace  = "ecs"
  resource_id        = "service/${local.ecs_service.ecs_cluster_name}/${aws_ecs_service.service[0].name}"
  scalable_dimension = "ecs:service:DesiredCount"

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = local.memory.scale_up.cooldown
    metric_aggregation_type = "Maximum"

    step_adjustment {
      metric_interval_lower_bound = local.memory.scale_up.lower_bound
      scaling_adjustment          = local.memory.scale_up.scale_by
    }
  }
  depends_on = [aws_appautoscaling_target.scale_target]
}

# Automatically scale capacity DOWN by one
resource "aws_appautoscaling_policy" "mem_down" {
  count              = var.enable_module && local.scaling_policies.enabled && local.memory.scale_down_enabled ? 1 : 0
  name               = "${var.environment}_${var.ecs_cluster_prefix}_${local.task_definition.task_name}_mem_scale_down"
  service_namespace  = "ecs"
  resource_id        = "service/${local.ecs_service.ecs_cluster_name}/${aws_ecs_service.service[0].name}"
  scalable_dimension = "ecs:service:DesiredCount"

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = local.memory.scale_down.cooldown
    metric_aggregation_type = "Maximum"

    step_adjustment {
      metric_interval_upper_bound = local.memory.scale_down.upper_bound
      scaling_adjustment          = local.memory.scale_down.scale_by
    }
  }
  depends_on = [aws_appautoscaling_target.scale_target]
}

# CloudWatch alarm that triggers the autoscaling UP policy
resource "aws_cloudwatch_metric_alarm" "mem_high" {
  count               = var.enable_module && local.scaling_policies.enabled && local.memory.scale_up_enabled ? 1 : 0
  alarm_name          = "${var.environment}_${var.ecs_cluster_prefix}_${local.task_definition.task_name}_memory_utilization_high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = local.memory.scale_up.evaluation_periods
  metric_name         = "MemoryUtilization"
  namespace           = "AWS/ECS"
  period              = local.memory.scale_up.period
  statistic           = "Average"
  threshold           = local.memory.scale_up.threshold
  alarm_description   = "ECS Service Memory utilization is too high - scaling up tasks"

  dimensions = {
    ClusterName = local.ecs_service.ecs_cluster_name
    ServiceName = aws_ecs_service.service[0].name
  }
  # alarm_actions = [aws_appautoscaling_policy.mem_up[0].arn] // without sns alerts

  # Combine autoscaling action with SNS alerts (if enabled)
  alarm_actions = compact([
    aws_appautoscaling_policy.mem_up[0].arn,
    local.alerts.enabled && local.enabled_alerts.memory_high ? aws_sns_topic.alerts[0].arn : null
  ])

  # Send alerts when alarm resolves
  ok_actions = local.alerts.enabled && local.enabled_alerts.memory_high ? [aws_sns_topic.alerts[0].arn] : []

  tags = merge(
    var.common_tags,
    {
      Component  = "alarm_metric_memory_utilization_high"
      AlertLevel = "HIGH"
      MetricType = "MEMORY"
    }
  )
}

# CloudWatch alarm that triggers the autoscaling DOWN policy
resource "aws_cloudwatch_metric_alarm" "mem_low" {
  count               = var.enable_module && local.scaling_policies.enabled && local.memory.scale_down_enabled ? 1 : 0
  alarm_name          = "${var.environment}_${var.ecs_cluster_prefix}_${local.task_definition.task_name}_memory_utilization_low"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = local.memory.scale_down.evaluation_periods
  metric_name         = "MemoryUtilization"
  namespace           = "AWS/ECS"
  period              = local.memory.scale_down.period
  statistic           = "Average"
  threshold           = local.memory.scale_down.threshold
  alarm_description   = "ECS Service Memory utilization is low - scaling down tasks"

  dimensions = {
    ClusterName = local.ecs_service.ecs_cluster_name
    ServiceName = aws_ecs_service.service[0].name
  }

  # alarm_actions = [aws_appautoscaling_policy.mem_down[0].arn] // without sns alerts

  # Combine autoscaling action with SNS alerts (if enabled for low alerts)
  alarm_actions = compact([
    aws_appautoscaling_policy.mem_down[0].arn,
    local.alerts.enabled && local.enabled_alerts.memory_low ? aws_sns_topic.alerts[0].arn : null
  ])

  # Send alerts when alarm resolves
  ok_actions = local.alerts.enabled && local.enabled_alerts.memory_low ? [aws_sns_topic.alerts[0].arn] : []

  tags = merge(
    var.common_tags,
    {
      Component  = "alarm_metric_memory_utilization_low"
      AlertLevel = "LOW"
      MetricType = "MEMORY"
    }
  )
}

#####################################################
## ECS: ecs cloudwatch logs
#####################################################
# Set up CloudWatch group and log stream and retain logs for 30 days
resource "aws_cloudwatch_log_group" "log_group" {
  count             = var.enable_module ? 1 : 0
  name              = "/ecs/${var.environment}-${var.ecs_cluster_prefix}-${local.task_definition.task_name}"
  retention_in_days = lookup({ "production" = 90, "uat" = 30, "staging" = 14, "development" = 7 }, var.environment, 7)

  tags = {
    Name = "${var.environment}-${var.ecs_cluster_prefix}-${local.task_definition.task_name}-log-group"
  }
}

resource "aws_cloudwatch_log_stream" "log_stream" {
  count          = var.enable_module ? 1 : 0
  name           = "${var.environment}-${var.ecs_cluster_prefix}-${local.task_definition.task_name}-log-stream"
  log_group_name = aws_cloudwatch_log_group.log_group[0].name
}

##--------------------------------------------------
## Scaling: Target Tracking (optional)
## AWS manages scale-up/down automatically to hit target_value
##--------------------------------------------------
resource "aws_appautoscaling_policy" "target_tracking" {
  count              = var.enable_module && local.scaling_policies.enabled && local.target_tracking.enabled ? 1 : 0
  name               = "${var.environment}_${var.ecs_cluster_prefix}_${local.task_definition.task_name}_target_tracking"
  service_namespace  = "ecs"
  resource_id        = "service/${local.ecs_service.ecs_cluster_name}/${aws_ecs_service.service[0].name}"
  scalable_dimension = "ecs:service:DesiredCount"
  policy_type        = "TargetTrackingScaling"

  target_tracking_scaling_policy_configuration {
    target_value       = local.target_tracking.target_value
    scale_in_cooldown  = local.target_tracking.scale_in_cooldown
    scale_out_cooldown = local.target_tracking.scale_out_cooldown
    disable_scale_in   = local.target_tracking.disable_scale_in

    # Predefined metric — CPU or Memory
    dynamic "predefined_metric_specification" {
      for_each = local.target_tracking.metric != "ALBRequestCountPerTarget" ? [1] : []
      content {
        predefined_metric_type = local.target_tracking.metric
      }
    }

    # ALBRequestCountPerTarget requires the TG ARN suffix
    dynamic "predefined_metric_specification" {
      for_each = local.target_tracking.metric == "ALBRequestCountPerTarget" ? [1] : []
      content {
        predefined_metric_type = "ALBRequestCountPerTarget"
        resource_label         = local.target_tracking.alb_target_group_arn_suffix
      }
    }
  }

  depends_on = [aws_appautoscaling_target.scale_target]
}

##--------------------------------------------------
## Scaling: Scheduled Actions (optional)
## Scale to fixed count at specific time or cron schedule
##--------------------------------------------------
resource "aws_appautoscaling_scheduled_action" "scheduled" {
  for_each = var.enable_module && local.scaling_policies.enabled ? {
    for a in local.scheduled_actions : a.name => a
  } : {}

  name               = "${var.environment}-${var.ecs_cluster_prefix}-${local.task_definition.task_name}-${each.key}"
  service_namespace  = "ecs"
  resource_id        = "service/${local.ecs_service.ecs_cluster_name}/${aws_ecs_service.service[0].name}"
  scalable_dimension = "ecs:service:DesiredCount"

  # One-time: schedule = "at(2026-12-31T23:59:00)"
  # Recurring: recurrence = "cron(0 8 * * MON-FRI)"
  schedule = each.value.schedule != null ? each.value.schedule : "cron(${each.value.recurrence})"
  timezone = each.value.timezone

  scalable_target_action {
    min_capacity = each.value.min_capacity
    max_capacity = each.value.max_capacity
  }

  depends_on = [aws_appautoscaling_target.scale_target]
}
