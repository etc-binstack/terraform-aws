output "lambda_arn"             { value = module.alarm_notifier.lambda_arn }
output "all_lambda_arns"        { value = module.alarm_notifier.all_lambda_arns }
output "lambda_role_arn"        { value = module.alarm_notifier.lambda_role_arn }
output "enabled_notifications"  { value = module.alarm_notifier.enabled_notifications }
