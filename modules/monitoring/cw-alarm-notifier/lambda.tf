## ==================================
## COMMON for Lambda Function
## ==================================
resource "random_id" "this" {
  count       = var.enable_module ? 1 : 0
  byte_length = 3 // ${random_id.this[count.index].hex}
}

## ==================================
## IAM Roles and Policies for Lambda
## ==================================
resource "aws_iam_role" "lambda_role" {
  count = var.enable_module ? 1 : 0
  name  = "${var.environment}-${var.project}-${local.lambda.role_name}-${random_id.this[0].hex}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_policy" "lambda_policies" {
  for_each = var.enable_module ? toset(local.policies) : []

  name   = "${var.environment}-${var.project}-${replace(each.key, ".json", "")}-${random_id.this[0].hex}"
  policy = templatefile("${path.module}/templates/policies/${each.key}", local.template_vars)

  tags = merge(var.tags, {
    PolicyFile = each.key
    Module     = "cw-alarm-notifier"
  })
}

resource "aws_iam_role_policy_attachment" "lambda_policy_attach" {
  for_each = var.enable_module ? aws_iam_policy.lambda_policies : {}

  policy_arn = each.value.arn
  role       = aws_iam_role.lambda_role[0].name
}

## (Optional) Lambda function get the secretkey from crossaccount vault
resource "aws_iam_policy" "vault" {
  count       = var.enable_module && local.cross_vault.enabled ? 1 : 0
  name        = "${var.environment}-${var.project}-AWSCrossAccountSecretAccess-${random_id.this[0].hex}"
  description = "Allow Lambda to read notification API keys from cross-account Secrets Manager"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AccessSecretsManagerInCrossAccount"
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "kms:Decrypt",
        "kms:GenerateDataKey*",
        "kms:DescribeKey"
      ]
      Resource = [
        "arn:aws:secretsmanager:${var.aws_region}:${local.cross_vault.account_id}:secret:*",
        "arn:aws:kms:${var.aws_region}:${local.cross_vault.account_id}:key/*",
        "arn:aws:secretsmanager:${local.cross_vault.region}:${local.cross_vault.account_id}:secret:*",
        "arn:aws:kms:${local.cross_vault.region}:${local.cross_vault.account_id}:key/*"
      ]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "vault" {
  count      = var.enable_module && local.cross_vault.enabled ? 1 : 0
  role       = aws_iam_role.lambda_role[0].name
  policy_arn = aws_iam_policy.vault[0].arn
}

## =======================================
## LAMBDA Function: For Combine Mode
## =======================================
resource "aws_lambda_function" "generic_mailer" {
  count         = var.enable_module && local.enable_combine ? 1 : 0
  filename      = "${path.module}/templates/lambda/generic_mailer/alerts_generic.zip" //alerts_generic_mailer.zip"
  function_name = "${var.environment}-${var.project}-${local.lambda.function_name}-combined-${random_id.this[0].hex}"
  role          = aws_iam_role.lambda_role[0].arn
  handler       = "alerts_generic.lambda_handler" //"alerts_generic_mailer.lambda_handler"
  runtime       = local.lambda.runtime
  timeout       = local.lambda.timeout

  environment {
    variables = merge(
      {
        MAIL_PROVIDER       = local.combined_provider
        MAIL_SERVER_API_KEY = local.environment.api_key
        MAIL_TEMPLATE       = local.environment.mail_template != null ? local.environment.mail_template : "html_template.html"
        EMAIL_FROM_ADDRESS  = local.environment.email_from
        EMAIL_TO_ADDRESSES  = join(",", local.environment.email_to)
        EMAIL_CC_ADDRESSES  = join(",", local.environment.email_cc)
        ENABLE_TEAMS        = local.environment.enable_teams
        TEAMS_WEBHOOK_URL   = local.environment.teams_webhook_url
      },
      local.cross_vault.enabled ? {
        VAULT_REGION     = local.cross_vault.region
        VAULT_ACCOUNT_ID = local.cross_vault.account_id
      } : {}
    )
  }

  tags = var.tags
}

## =======================================
## LAMBDA Function: For Postmark
## =======================================
resource "aws_lambda_function" "lambda_postmark" {
  count         = var.enable_module && local.enable_postmark ? 1 : 0
  filename      = "${path.module}/templates/lambda/postmark/postmark_cw_alerts.zip"
  function_name = "${var.environment}-${var.project}-${local.lambda.function_name}-postmark-${random_id.this[0].hex}"
  role          = aws_iam_role.lambda_role[0].arn
  handler       = "postmark_cw_alerts.lambda_handler"
  runtime       = local.lambda.runtime
  timeout       = local.lambda.timeout

  environment {
    variables = merge(
      {
        POSTMARK_API_KEY   = local.environment.api_key
        EMAIL_FROM_ADDRESS = local.environment.email_from
        EMAIL_TO_ADDRESSES = join(",", local.environment.email_to)
        EMAIL_CC_ADDRESSES = join(",", local.environment.email_cc)
      },
      local.cross_vault.enabled ? {
        VAULT_REGION     = local.cross_vault.region
        VAULT_ACCOUNT_ID = local.cross_vault.account_id
      } : {}
    )
  }

  tags = var.tags
}

## =======================================
## LAMBDA Function: For SendGrid
## =======================================
resource "aws_lambda_function" "lambda_sendgrid" {
  count         = var.enable_module && local.enable_sendgrid ? 1 : 0
  filename      = "${path.module}/templates/lambda/sendgrid/sendgrid_cw_alerts.zip"
  function_name = "${var.environment}-${var.project}-${local.lambda.function_name}-sendgrid-${random_id.this[0].hex}"
  role          = aws_iam_role.lambda_role[0].arn
  handler       = "sendgrid_cw_alerts.lambda_handler"
  runtime       = local.lambda.runtime
  timeout       = local.lambda.timeout

  environment {
    variables = merge(
      {
        SENDGRID_API_KEY   = local.environment.api_key
        EMAIL_FROM_ADDRESS = local.environment.email_from
        EMAIL_TO_ADDRESSES = join(",", local.environment.email_to)
        EMAIL_CC_ADDRESSES = join(",", local.environment.email_cc)
      },
      local.cross_vault.enabled ? {
        VAULT_REGION     = local.cross_vault.region
        VAULT_ACCOUNT_ID = local.cross_vault.account_id
      } : {}
    )
  }

  tags = var.tags
}

## =======================================
## LAMBDA Function: For SES
## =======================================
data "archive_file" "lambda_ses" {
  count       = var.enable_module && local.enable_ses ? 1 : 0
  type        = "zip"
  source_file = "${path.module}/templates/lambda/ses/ses_cw_alerts.py"
  output_path = "${path.module}/templates/lambda/ses/ses_cw_alerts.zip"
}

resource "aws_lambda_function" "lambda_ses" {
  count         = var.enable_module && local.enable_ses ? 1 : 0
  filename      = data.archive_file.lambda_ses[0].output_path
  function_name = "${var.environment}-${var.project}-${local.lambda.function_name}-ses-${random_id.this[0].hex}"
  role          = aws_iam_role.lambda_role[0].arn
  handler       = "ses_cw_alerts.lambda_handler"
  runtime       = local.lambda.runtime
  timeout       = local.lambda.timeout

  environment {
    variables = {
      SES_TEMPLATE             = local.environment.mail_template != null ? local.environment.mail_template : "sesTemplateCloudWatchAlerts"
      EMAIL_FROM_ADDRESS       = local.environment.email_from
      EMAIL_TO_ADDRESSES       = join(",", local.environment.email_to)
      EMAIL_CC_ADDRESSES       = join(",", local.environment.email_cc)
      EMAIL_REPLY_TO_ADDRESSES = join(",", local.environment.email_reply_to)
    }
  }

  tags = var.tags
}