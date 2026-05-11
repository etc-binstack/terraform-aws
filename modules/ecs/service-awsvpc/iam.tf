#####################################################
## ECS: IAM Roles & Policies  
#####################################################

## ECS: TASK ROLE
## --------------
data "aws_iam_policy_document" "task_role" {
  version = "2012-10-17"
  statement {
    sid     = ""
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "task_role" {
  count              = var.enable_module ? 1 : 0
  name               = "${var.environment}-${var.ecs_cluster_prefix}-${local.task_definition.task_name}-task-role-${local.random_id}"
  assume_role_policy = data.aws_iam_policy_document.task_role.json
}


## ECS: TASK EXECUTION ROLE
## ------------------------
data "aws_iam_policy_document" "task_exec_role" {
  version = "2012-10-17"
  statement {
    sid     = ""
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "task_exec_role" {
  count              = var.enable_module ? 1 : 0
  name               = "${var.environment}-${var.ecs_cluster_prefix}-${local.task_definition.task_name}-taskexec-role-${local.random_id}"
  assume_role_policy = data.aws_iam_policy_document.task_exec_role.json
}


## ECS: IAM POLICIES & ROLE ATTACHMENT
## -----------------------------------
## Policy for Same Account Access (SSM and Secrets Manager)
## Scope: wildcard when secret_path_prefix = null (default, backward compat)
## path-scoped when secret_path_prefix is set (opt-in, least privilege)
resource "aws_iam_policy" "task_role_vault_policy" {
  count       = var.enable_module ? 1 : 0
  name        = "${var.environment}-${var.ecs_cluster_prefix}-${local.task_definition.task_name}-vault-policy-${local.random_id}"
  description = "Policy for access to Secrets Manager and SSM keys in the same account"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AccessSSMAndSecretsManagerInSameAccount"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
          "kms:Decrypt",
          "ssm:GetParameters",
          "ssm:GetParameter"
        ]
        Resource = var.secret_path_prefix != null ? [
          "arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:parameter/${var.secret_path_prefix}/*",
          "arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:${var.secret_path_prefix}/*",
          "arn:aws:kms:${var.aws_region}:${var.aws_account_id}:key/*"
        ] : [
          "arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:parameter/*",
          "arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:*",
          "arn:aws:kms:${var.aws_region}:${var.aws_account_id}:key/*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "attach_vault_policy_to_task_role" {
  count      = var.enable_module ? 1 : 0
  role       = aws_iam_role.task_role[0].name
  policy_arn = aws_iam_policy.task_role_vault_policy[0].arn
}

resource "aws_iam_role_policy_attachment" "attach_vault_policy_to_task_exec_role" {
  count      = var.enable_module ? 1 : 0
  role       = aws_iam_role.task_exec_role[0].name
  policy_arn = aws_iam_policy.task_role_vault_policy[0].arn
}

## Policy for Cross-Account Secrets Manager Access
## Scope: wildcard when cross_account_secret_path_prefix = null (default, backward compat)
## path-scoped when cross_account_secret_path_prefix is set (opt-in, least privilege)
resource "aws_iam_policy" "task_role_cross_account_policy" {
  count       = var.enable_module && var.aws_cross_account_id != null ? 1 : 0
  name        = "${var.environment}-${var.ecs_cluster_prefix}-${local.task_definition.task_name}-cross-account-vault-policy-${local.random_id}"
  description = "Policy for accessing Secrets Manager in a cross-account"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AccessSecretsManagerInCrossAccount"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "kms:Decrypt"
        ]
        Resource = var.cross_account_secret_path_prefix != null ? [
          "arn:aws:secretsmanager:${var.aws_region}:${var.aws_cross_account_id}:secret:${var.cross_account_secret_path_prefix}/*",
          "arn:aws:kms:${var.aws_region}:${var.aws_cross_account_id}:key/*"
        ] : [
          "arn:aws:secretsmanager:${var.aws_region}:${var.aws_cross_account_id}:secret:*",
          "arn:aws:kms:${var.aws_region}:${var.aws_cross_account_id}:key/*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "attach_cross_account_policy_to_task_role" {
  count      = var.enable_module && var.aws_cross_account_id != null ? 1 : 0
  role       = aws_iam_role.task_role[0].name
  policy_arn = aws_iam_policy.task_role_cross_account_policy[0].arn
}

resource "aws_iam_role_policy_attachment" "attach_cross_account_policy_to_task_exec_role" {
  count      = var.enable_module && var.aws_cross_account_id != null ? 1 : 0
  role       = aws_iam_role.task_exec_role[0].name
  policy_arn = aws_iam_policy.task_role_cross_account_policy[0].arn
}

resource "aws_iam_role_policy_attachment" "managed_policy_02" {
  count      = var.enable_module ? 1 : 0
  role       = aws_iam_role.task_exec_role[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

## -------------------------------------------------------
## ECS Exec: SSM permissions (when enable_exec_command = true)
## ssmmessages actions do not support resource-level restrictions — Resource = "*" required
## -------------------------------------------------------
resource "aws_iam_policy" "ecs_exec" {
  count       = var.enable_module && var.enable_exec_command ? 1 : 0
  name        = "${var.environment}-${var.ecs_cluster_prefix}-${local.task_definition.task_name}-exec-policy-${local.random_id}"
  description = "Allow ECS Exec (SSM session) into running containers"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "ECSExecSSMPermissions"
      Effect = "Allow"
      Action = [
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel"
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "attach_ecs_exec" {
  count      = var.enable_module && var.enable_exec_command ? 1 : 0
  role       = aws_iam_role.task_role[0].name
  policy_arn = aws_iam_policy.ecs_exec[0].arn
}

## -------------------------------------------------------
## FireLens / Fluent Bit: Kinesis logging permissions
## -------------------------------------------------------

## Same-account: task role writes directly to Kinesis streams
## Created when fluentbit enabled AND no cross-account role (same account path)
resource "aws_iam_policy" "kinesis_same_account" {
  count       = var.enable_module && local.fluentbit.enable_fluentbit && local.kinesis_cross_account_role_arn == null ? 1 : 0
  name        = "${var.environment}-${var.ecs_cluster_prefix}-${local.task_definition.task_name}-kinesis-policy-${local.random_id}"
  description = "Allow Fluent Bit to write logs to Kinesis streams in the same account"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "KinesisLogWrite"
      Effect = "Allow"
      Action = ["kinesis:PutRecord", "kinesis:PutRecords"]
      Resource = [
        "arn:aws:kinesis:${var.aws_region}:${var.aws_account_id}:stream/${var.environment}-*"
      ]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "attach_kinesis_same_account" {
  count      = var.enable_module && local.fluentbit.enable_fluentbit && local.kinesis_cross_account_role_arn == null ? 1 : 0
  role       = aws_iam_role.task_role[0].name
  policy_arn = aws_iam_policy.kinesis_same_account[0].arn
}

## Cross-account: task role assumes writer role in central logs account
## Created when fluentbit enabled AND kinesis_cross_account_role_arn is set
resource "aws_iam_policy" "kinesis_cross_account_assume" {
  count       = var.enable_module && local.fluentbit.enable_fluentbit && local.kinesis_cross_account_role_arn != null ? 1 : 0
  name        = "${var.environment}-${var.ecs_cluster_prefix}-${local.task_definition.task_name}-kinesis-xaccount-policy-${local.random_id}"
  description = "Allow Fluent Bit to assume Kinesis writer role in central logs account"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "AssumeKinesisWriterRole"
      Effect   = "Allow"
      Action   = "sts:AssumeRole"
      Resource = local.kinesis_cross_account_role_arn
    }]
  })
}

resource "aws_iam_role_policy_attachment" "attach_kinesis_cross_account" {
  count      = var.enable_module && local.fluentbit.enable_fluentbit && local.kinesis_cross_account_role_arn != null ? 1 : 0
  role       = aws_iam_role.task_role[0].name
  policy_arn = aws_iam_policy.kinesis_cross_account_assume[0].arn
}

## S3 config fetch: execution role reads custom fluent-bit.conf from S3
## Created when fluentbit_config_s3_arn is set
resource "aws_iam_policy" "fluentbit_s3_config" {
  count       = var.enable_module && local.fluentbit.enable_fluentbit && local.fluentbit_config_s3_arn != null ? 1 : 0
  name        = "${var.environment}-${var.ecs_cluster_prefix}-${local.task_definition.task_name}-fluentbit-s3-policy-${local.random_id}"
  description = "Allow ECS execution role to fetch Fluent Bit config from S3"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "FluentBitConfigFetch"
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = local.fluentbit_config_s3_arn
    }]
  })
}

resource "aws_iam_role_policy_attachment" "attach_fluentbit_s3_config" {
  count      = var.enable_module && local.fluentbit.enable_fluentbit && local.fluentbit_config_s3_arn != null ? 1 : 0
  role       = aws_iam_role.task_exec_role[0].name
  policy_arn = aws_iam_policy.fluentbit_s3_config[0].arn
}