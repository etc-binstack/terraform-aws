## =========================================
## Cluster Outputs
## =========================================
output "cluster_id" {
  description = "ECS cluster ID"
  value       = var.enable_module ? aws_ecs_cluster.cluster[0].id : null
}

output "cluster_name" {
  description = "ECS cluster name"
  value       = var.enable_module ? aws_ecs_cluster.cluster[0].name : null
}

output "cluster_arn" {
  description = "ECS cluster ARN"
  value       = var.enable_module ? aws_ecs_cluster.cluster[0].arn : null
}

## Legacy aliases — backward compatible
output "ecs_cluster_id" {
  description = "ECS cluster ID (alias for cluster_id)"
  value       = var.enable_module ? aws_ecs_cluster.cluster[0].id : null
}

output "ecs_cluster_name" {
  description = "ECS cluster name (alias for cluster_name)"
  value       = var.enable_module ? aws_ecs_cluster.cluster[0].name : null
}

## =========================================
## Capacity Provider Outputs
## =========================================
output "active_capacity_providers" {
  description = "List of active capacity provider names on this cluster"
  value       = var.enable_module ? local.active_capacity_providers : []
}

output "ec2_capacity_provider_name" {
  description = "EC2 capacity provider name. Pass to configure_ecs_service.capacity_provider_strategy in service module."
  value       = var.enable_module && local.ec2.enabled ? aws_ecs_capacity_provider.ec2[0].name : null
}

output "ec2_asg_arn" {
  description = "EC2 Auto Scaling Group ARN"
  value       = var.enable_module && local.ec2.enabled ? aws_autoscaling_group.ec2[0].arn : null
}

output "ec2_asg_name" {
  description = "EC2 Auto Scaling Group name"
  value       = var.enable_module && local.ec2.enabled ? aws_autoscaling_group.ec2[0].name : null
}

output "ec2_launch_template_id" {
  description = "EC2 launch template ID"
  value       = var.enable_module && local.ec2.enabled ? aws_launch_template.ec2[0].id : null
}

output "ec2_instance_role_arn" {
  description = "IAM role ARN attached to EC2 instances"
  value       = var.enable_module && local.ec2.enabled ? aws_iam_role.ec2_instance_role[0].arn : null
}

## =========================================
## Service Discovery Outputs
## =========================================
output "ecs_namespace_id" {
  description = "Cloud Map namespace ID"
  value       = var.namespace_configuration.enabled ? local.namespace_id : null
}

output "ecs_namespace_arn" {
  description = "Cloud Map namespace ARN"
  value       = var.namespace_configuration.enabled ? local.namespace_arn : null
}

output "ecs_namespace_name" {
  description = "Cloud Map namespace name"
  value       = var.namespace_configuration.enabled ? local.namespace_name : null
}

output "namespace_source" {
  description = "created | existing | disabled"
  value = var.namespace_configuration.enabled ? (
    var.namespace_configuration.create_new ? "created" : "existing"
  ) : "disabled"
}
