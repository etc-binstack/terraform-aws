## ===========================================
## SNS Topic and Subscriptions for Alerts
## ===========================================

# Create SNS Topic for ECS Autoscaling Alerts
resource "aws_sns_topic" "alerts" {
  count = var.enable_module && local.alerts.enabled ? 1 : 0
  name  = "${var.environment}-${var.ecs_cluster_prefix}-${local.task_definition.task_name}-${local.alerts.topic_name}"

  tags = merge(
    var.common_tags,
    {
      Component = "sns_topic_ecs_autoscaling_alerts"
      Purpose   = "ECS Autoscaling Notifications"
    }
  )
}

# Email Subscriptions
resource "aws_sns_topic_subscription" "email_alerts" {
  count     = var.enable_module && local.alerts.enabled ? length(local.alerts.email_endpoints) : 0
  topic_arn = aws_sns_topic.alerts[0].arn
  protocol  = "email"
  endpoint  = local.alerts.email_endpoints[count.index]
}

# SMS Subscriptions
resource "aws_sns_topic_subscription" "sms_alerts" {
  count     = var.enable_module && local.alerts.enabled ? length(local.alerts.sms_endpoints) : 0
  topic_arn = aws_sns_topic.alerts[0].arn
  protocol  = "sms"
  endpoint  = local.alerts.sms_endpoints[count.index]
}

## AWS Lambda Subscriptions
resource "aws_sns_topic_subscription" "lambda_alerts" {
  count     = var.enable_module && local.alerts.enabled && length(local.alerts.lambda_arns) > 0 ? length(local.alerts.lambda_arns) : 0
  topic_arn = aws_sns_topic.alerts[0].arn
  protocol  = "lambda"
  endpoint  = local.alerts.lambda_arns[count.index]
}

## SNS invoke Lambda to create trigger for SNS
resource "aws_lambda_permission" "allow_sns_to_invoke_lambda" {
  count         = var.enable_module && local.alerts.enabled && length(local.alerts.lambda_arns) > 0 ? length(local.alerts.lambda_arns) : 0
  statement_id  = "AllowSNSInvoke-${count.index}-${random_id.this[0].hex}"
  action        = "lambda:InvokeFunction"
  function_name = element(split(":", local.alerts.lambda_arns[count.index]), 6)
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.alerts[0].arn
}

# Optional: HTTPS endpoint for Slack/Teams webhooks
resource "aws_sns_topic_subscription" "webhook_alerts" {
  count     = var.enable_module && local.alerts.enabled && local.alerts.slack_webhook_url != null ? 1 : 0
  topic_arn = aws_sns_topic.alerts[0].arn
  protocol  = "https"
  endpoint  = local.alerts.slack_webhook_url
}