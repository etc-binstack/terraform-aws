## ============================================================
## ECS Task & Service Outputs
## ============================================================

output "task_definition_arn" {
  description = "Full ARN of the ECS task definition including revision"
  value       = var.enable_module ? aws_ecs_task_definition.task[0].arn : null
}

output "task_definition_family" {
  description = "Task definition family name (without revision)"
  value       = var.enable_module ? aws_ecs_task_definition.task[0].family : null
}

output "ecs_service_name" {
  description = "ECS service name"
  value       = var.enable_module ? aws_ecs_service.service[0].name : null
}

output "ecs_service_id" {
  description = "ECS service ID"
  value       = var.enable_module ? aws_ecs_service.service[0].id : null
}

## ============================================================
## IAM Outputs
## ============================================================

output "task_role_arn" {
  description = "IAM task role ARN — pass to other modules needing same runtime permissions"
  value       = var.enable_module ? aws_iam_role.task_role[0].arn : null
}

output "task_exec_role_arn" {
  description = "IAM execution role ARN"
  value       = var.enable_module ? aws_iam_role.task_exec_role[0].arn : null
}

output "security_group_id" {
  description = "Security group ID — attach to RDS, Redis, or other services to allow ECS task access"
  value       = var.enable_module ? aws_security_group.sgp[0].id : null
}

## ============================================================
## Load Balancer Outputs (map — one entry per configure_load_balancers name)
## Access: module.svc.target_group_arns["public-alb"]
## ============================================================

output "target_group_arns" {
  description = "Map of target group ARNs keyed by load balancer name"
  value       = var.enable_module ? { for name, tg in aws_lb_target_group.tg : name => tg.arn } : {}
}

output "listener_rule_arns" {
  description = "Map of listener rule ARNs keyed by load balancer name"
  value       = var.enable_module ? { for name, rule in aws_lb_listener_rule.rule : name => rule.arn } : {}
}

output "dns_record_fqdns" {
  description = "Map of Route53 record FQDNs keyed by load balancer name"
  value       = var.enable_module ? { for name, rec in aws_route53_record.a_alias : name => rec.fqdn } : {}
}

## ============================================================
## CloudWatch Outputs
## ============================================================

output "cloudwatch_log_group_name" {
  description = "CloudWatch log group name for container logs"
  value       = var.enable_module ? aws_cloudwatch_log_group.log_group[0].name : null
}

## ============================================================
## SNS / Alerts Outputs
## ============================================================

output "sns_topic_arn" {
  description = "ARN of the SNS topic for ECS autoscaling alerts"
  value       = var.enable_module && local.alerts.enabled ? aws_sns_topic.alerts[0].arn : null
}

output "sns_topic_name" {
  description = "Name of the SNS topic for ECS autoscaling alerts"
  value       = var.enable_module && local.alerts.enabled ? aws_sns_topic.alerts[0].name : null
}

## ============================================================
## Scaling Outputs
## ============================================================

output "target_tracking_policy_arn" {
  description = "ARN of target tracking scaling policy (null when disabled)"
  value       = var.enable_module && local.scaling_policies.enabled && local.target_tracking.enabled ? aws_appautoscaling_policy.target_tracking[0].arn : null
}

output "scheduled_action_names" {
  description = "List of scheduled scaling action names"
  value       = var.enable_module ? [for a in aws_appautoscaling_scheduled_action.scheduled : a.name] : []
}
