# Configuration Guide — Per-Environment tfvars

Copy the appropriate block into your `terraform.tfvars` or environment-specific `.tfvars` file.

---

## Development

```hcl
# environments/dev/terraform.tfvars

environment         = "development"
aws_region          = "<your-region>"
project_name        = "sample-app"

# IAM — wildcard (dev has no sensitive secrets)
secret_path_prefix  = null

# ECS Exec — enable for debugging
enable_exec_command = true

# Task
stop_timeout        = 30

# Scaling — minimal, cost saving
# configure_ecs_service.scaling_capacity
desired_count       = 1
min_capacity        = 1
max_capacity        = 3

# Logging — same account Kinesis
kinesis_stream_name               = "development-app-logs"
kinesis_cross_account_role_arn    = null

# Alerts — email only, no PagerDuty
oncall_email        = "dev-team@example.com"
```

---

## Staging

```hcl
# environments/staging/terraform.tfvars

environment         = "staging"
aws_region          = "<your-region>"
project_name        = "sample-app"

# IAM — scoped to staging path
secret_path_prefix  = "staging/sample-app"

# ECS Exec — enable for QA debugging
enable_exec_command = true

# Task
stop_timeout        = 60

# Scaling
desired_count       = 2
min_capacity        = 1
max_capacity        = 5

# Logging
kinesis_stream_name               = "staging-app-logs"
kinesis_cross_account_role_arn    = null   # same account or set central logs ARN

# Alerts
oncall_email        = "qa-team@example.com"
```

---

## UAT

```hcl
# environments/uat/terraform.tfvars

environment         = "uat"
aws_region          = "<your-region>"
project_name        = "sample-app"

# IAM — scoped
secret_path_prefix  = "uat/sample-app"

# ECS Exec — allow for client acceptance testing support
enable_exec_command = true

# Task
stop_timeout        = 60

# Scaling
desired_count       = 2
min_capacity        = 1
max_capacity        = 8

# Logging
kinesis_stream_name               = "uat-app-logs"
kinesis_cross_account_role_arn    = null

# Alerts
oncall_email        = "platform-team@example.com"
```

---

## Production

```hcl
# environments/prod/terraform.tfvars

environment         = "production"
aws_region          = "<your-region>"
project_name        = "sample-app"

# IAM — always scope in production
secret_path_prefix               = "production/sample-app"
cross_account_secret_path_prefix = "production/sample-app"   # if using cross-account secrets

# ECS Exec — OFF by default in prod. Enable per-incident only.
enable_exec_command = false

# Task — longer shutdown for in-flight requests
stop_timeout        = 120

# Scaling — HA baseline
desired_count       = 2
min_capacity        = 2
max_capacity        = 20

# Logging — cross-account central logs account
kinesis_stream_name            = "production-app-logs"
kinesis_cross_account_role_arn = "arn:aws:iam::LOGS_ACCOUNT_ID:role/kinesis-cross-account-writer"

# Custom Fluent Bit config with PII filtering
fluentbit_config_s3_arn = "arn:aws:s3:::sample-app-obs-config/fluentbit/fluent-bit.conf"

# Alerts — email + PagerDuty Lambda
oncall_email = "oncall@example.com"
```

---

## Cross-Account Kinesis (central logs account)

When using a dedicated `aws-acctn-logs-00` account for all log streams:

```hcl
# App account tfvars — points to central logs account role
kinesis_stream_name            = "sample-app-production-app-logs"  # stream IN central account
kinesis_cross_account_role_arn = "arn:aws:iam::LOGS_ACCOUNT_ID:role/kinesis-cross-account-writer"

# No kinesis:PutRecord needed in app account IAM
# Module creates sts:AssumeRole permission automatically
```

See `docs/logging.md` for full cross-account architecture.

---

## Capacity Provider Strategy (FARGATE_SPOT)

For workers and non-critical services — override `launch_type` with capacity provider:

```hcl
# In module call — NOT in tfvars (Terraform object type)
configure_ecs_service = {
  capacity_provider_strategy = [
    { capacity_provider = "FARGATE_SPOT", weight = 1, base = 0 }
  ]
  task_compatibilities = ["FARGATE"]
  ...
}
```

See `docs/features.md` — Feature 2 for mixed FARGATE + SPOT pattern.
