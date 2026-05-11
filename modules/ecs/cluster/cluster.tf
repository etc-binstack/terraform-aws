## =========================================
## ECS Cluster
## =========================================
resource "aws_ecs_cluster" "cluster" {
  count = var.enable_module ? 1 : 0
  name  = local.ecs_cluster_name

  dynamic "setting" {
    for_each = var.monitoring_settings
    content {
      name  = setting.value.name
      value = setting.value.value
    }
  }

  tags       = var.tags
  depends_on = [aws_cloudwatch_log_group.create]
}

## CloudWatch log group — only when Container Insights enabled
resource "aws_cloudwatch_log_group" "create" {
  count             = var.enable_module && local.enable_containerinsights ? 1 : 0
  name              = "/aws/ecs/containerinsights/${local.ecs_cluster_name}/performance"
  retention_in_days = 30
  tags              = var.tags
}

## =========================================
## Capacity Providers — register with cluster
## FARGATE and FARGATE_SPOT: AWS-managed (no resources to create)
## EC2: created in ec2.tf, referenced by name here
## =========================================
resource "aws_ecs_cluster_capacity_providers" "this" {
  count        = var.enable_module ? 1 : 0
  cluster_name = aws_ecs_cluster.cluster[0].name

  capacity_providers = local.active_capacity_providers

  dynamic "default_capacity_provider_strategy" {
    for_each = local.default_capacity_provider_strategy
    content {
      capacity_provider = default_capacity_provider_strategy.value.capacity_provider
      base              = default_capacity_provider_strategy.value.base
      weight            = default_capacity_provider_strategy.value.weight
    }
  }

  depends_on = [aws_ecs_capacity_provider.ec2]
}

## =========================================
## Service Discovery (Cloud Map)
## =========================================

## Create new namespace
resource "aws_service_discovery_private_dns_namespace" "ecs_namespace" {
  count       = var.enable_module && var.namespace_configuration.enabled && var.namespace_configuration.create_new ? 1 : 0
  name        = var.namespace_configuration.namespace_name
  description = "ECS namespace for service discovery"
  vpc         = var.namespace_configuration.vpc_id

  tags = merge(var.tags, {
    NamespaceType = "DNS_Private"
    ClusterName   = local.ecs_cluster_name
  })
}

## Use existing namespace
data "aws_service_discovery_dns_namespace" "existing_namespace" {
  count = var.enable_module && var.namespace_configuration.enabled && !var.namespace_configuration.create_new ? 1 : 0
  name  = var.namespace_configuration.existing_namespace
  type  = "DNS_PRIVATE"
}
