output "ecs_service_name" {
  value = module.api_service.ecs_service_name
}

output "task_role_arn" {
  value = module.api_service.task_role_arn
}

output "security_group_id" {
  value = module.api_service.security_group_id
}

output "target_group_arns" {
  value = module.api_service.target_group_arns
}

output "dns_record_fqdns" {
  value = module.api_service.dns_record_fqdns
}
