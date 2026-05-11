locals {
  ## Cluster name: {environment}-{cluster_name}-cluster
  ecs_cluster_name = "${var.environment}-${var.cluster_name}-cluster"

  ## Container Insights toggle
  enable_containerinsights = anytrue([
    for setting in var.monitoring_settings :
    setting.name == "containerInsights" && contains(["enabled", "enhanced"], setting.value)
  ])

  ## Namespace resolution — new or existing
  namespace_id = var.namespace_configuration.enabled ? (
    var.namespace_configuration.create_new ?
    (length(aws_service_discovery_private_dns_namespace.ecs_namespace) > 0 ? aws_service_discovery_private_dns_namespace.ecs_namespace[0].id : null) :
    (length(data.aws_service_discovery_dns_namespace.existing_namespace) > 0 ? data.aws_service_discovery_dns_namespace.existing_namespace[0].id : null)
  ) : null

  namespace_arn = var.namespace_configuration.enabled ? (
    var.namespace_configuration.create_new ?
    (length(aws_service_discovery_private_dns_namespace.ecs_namespace) > 0 ? aws_service_discovery_private_dns_namespace.ecs_namespace[0].arn : null) :
    (length(data.aws_service_discovery_dns_namespace.existing_namespace) > 0 ? data.aws_service_discovery_dns_namespace.existing_namespace[0].arn : null)
  ) : null

  namespace_name = var.namespace_configuration.enabled ? (
    var.namespace_configuration.create_new ?
    (length(aws_service_discovery_private_dns_namespace.ecs_namespace) > 0 ? aws_service_discovery_private_dns_namespace.ecs_namespace[0].name : null) :
    (length(data.aws_service_discovery_dns_namespace.existing_namespace) > 0 ? data.aws_service_discovery_dns_namespace.existing_namespace[0].name : null)
  ) : null

  ## Capacity provider shortcuts
  fargate      = var.capacity_providers.fargate
  fargate_spot = var.capacity_providers.fargate_spot
  ec2          = var.capacity_providers.ec2

  ## Active capacity provider names for aws_ecs_cluster_capacity_providers
  active_capacity_providers = compact([
    local.fargate.enabled ? "FARGATE" : null,
    local.fargate_spot.enabled ? "FARGATE_SPOT" : null,
    local.ec2.enabled ? aws_ecs_capacity_provider.ec2[0].name : null
  ])

  ## Default capacity provider strategy for the cluster
  ## Services can override this with their own capacity_provider_strategy
  default_capacity_provider_strategy = [for s in [
    local.fargate.enabled ? {
      capacity_provider = "FARGATE"
      base              = local.fargate.default_base
      weight            = local.fargate.default_weight
    } : null,
    local.fargate_spot.enabled ? {
      capacity_provider = "FARGATE_SPOT"
      base              = local.fargate_spot.default_base
      weight            = local.fargate_spot.default_weight
    } : null,
    length(aws_ecs_capacity_provider.ec2) > 0 ? {
      capacity_provider = aws_ecs_capacity_provider.ec2[0].name
      base              = local.ec2.default_base
      weight            = local.ec2.default_weight
    } : null
  ] : s if s != null && (try(s.weight, 0) > 0 || try(s.base, 0) > 0)]

  ## EC2: resolve AMI — use provided or auto-resolve ECS-optimized AL2
  ec2_ami_id = local.ec2.enabled ? (
    local.ec2.ami_id != null ? local.ec2.ami_id :
    data.aws_ssm_parameter.ecs_optimized_ami[0].value
  ) : null

  ## EC2: base user data — registers instance with ECS cluster + enables task ENI
  ## ECS_ENABLE_TASK_ENI=true supports both awsvpc tasks and bridge tasks on same cluster
  ec2_user_data = base64encode(<<-EOF
    #!/bin/bash
    echo ECS_CLUSTER=${local.ecs_cluster_name} >> /etc/ecs/ecs.config
    echo ECS_ENABLE_TASK_ENI=true >> /etc/ecs/ecs.config
    ${local.ec2.enabled && local.ec2.extra_user_data != "" ? local.ec2.extra_user_data : ""}
  EOF
  )
}
