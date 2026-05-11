# --- Lambda Function ARN Outputs ---
output "sendgrid_lambda_arn" {
  description = "ARN of the SendGrid Lambda function"
  value       = var.enable_module && local.enable_sendgrid ? aws_lambda_function.lambda_sendgrid[0].arn : null
}

output "postmark_lambda_arn" {
  description = "ARN of the Postmark Lambda function"
  value       = var.enable_module && local.enable_postmark ? aws_lambda_function.lambda_postmark[0].arn : null
}

output "ses_lambda_arn" {
  description = "ARN of the SES Lambda function"
  value       = var.enable_module && local.enable_ses ? aws_lambda_function.lambda_ses[0].arn : null
}

output "generic_lambda_arn" {
  description = "ARN of the Generic/Combined Lambda function"
  value       = var.enable_module && local.enable_combine ? aws_lambda_function.generic_mailer[0].arn : null
}

# Combined output that returns the first available Lambda ARN
output "lambda_arn" {
  description = "ARN of the primary Lambda function based on configuration"
  value = var.enable_module ? coalesce(
    local.enable_sendgrid ? aws_lambda_function.lambda_sendgrid[0].arn : null,
    local.enable_postmark ? aws_lambda_function.lambda_postmark[0].arn : null,
    local.enable_ses ? aws_lambda_function.lambda_ses[0].arn : null,
    local.enable_combine ? aws_lambda_function.generic_mailer[0].arn : null
  ) : null
}

# Output all available Lambda ARNs as a list (excluding nulls)
output "all_lambda_arns" {
  description = "List of all created Lambda function ARNs"
  value = var.enable_module ? compact([
    local.enable_sendgrid ? aws_lambda_function.lambda_sendgrid[0].arn : null,
    local.enable_postmark ? aws_lambda_function.lambda_postmark[0].arn : null,
    local.enable_ses ? aws_lambda_function.lambda_ses[0].arn : null,
    local.enable_combine ? aws_lambda_function.generic_mailer[0].arn : null
  ]) : []
}

# --- IAM Role Outputs ---
output "lambda_role_name" {
  value       = var.enable_module ? aws_iam_role.lambda_role[0].name : null
  description = "Name of the IAM role used by the Lambda function(s)"
}

output "lambda_role_arn" {
  value       = var.enable_module ? aws_iam_role.lambda_role[0].arn : null
  description = "ARN of the IAM role used by the Lambda function(s)"
}


# --- Notification Configuration ---
output "enabled_notifications" {
  value       = local.notification_vendors
  description = "List of enabled notification vendors (e.g., sendgrid, ses)"
}
