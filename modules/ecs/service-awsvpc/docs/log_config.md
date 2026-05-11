# Logs Configuration Guide

Covers `configure_logs` inside `ecs_task_definition`. Two production architectures supported: same-account Kinesis and cross-account Kinesis (central logs account).

> Full architecture history including legacy static-key pattern: see `docs/CUSTOM_LOGS_CONFIG.md`.

---

## Table of Contents

- [How FireLens Logging Works](#how-firelens-logging-works)
- [Variable Reference](#variable-reference)
- [Architecture A — Same-Account Kinesis](#architecture-a--same-account-kinesis)
- [Architecture B — Cross-Account Kinesis (Central Logs Account)](#architecture-b--cross-account-kinesis-central-logs-account)
- [Custom Fluent Bit Config (S3-backed)](#custom-fluent-bit-config-s3-backed)
- [IAM — What Gets Created](#iam--what-gets-created)
- [Fluent Bit Environment Variables](#fluent-bit-environment-variables)
- [Comparison Table](#comparison-table)

---

## How FireLens Logging Works

```
App Container
  stdout JSON logs
       │
       │  logDriver: awsfirelens
       ▼
FireLens Sidecar (Fluent Bit)
  ├── enable-ecs-log-metadata injects: task ARN, cluster, task definition
  ├── custom fluent-bit.conf (S3) → PII filter, JSON parse, stream routing
  └── kinesis_streams OUTPUT plugin
            │
            │  same account: task role kinesis:PutRecord
            │  cross account: task role sts:AssumeRole → writer role kinesis:PutRecord
            ▼
     Kinesis Data Streams
            │
            ▼
     Data Prepper / Lambda
            │
            ▼
     OpenSearch + S3 Archive
```

Application containers use `awsfirelens` log driver — no `awslogs` when FireLens is enabled.
The Fluent Bit sidecar itself logs to CloudWatch (`/ecs/{env}-{cluster}-{task}/fluentbit`).

---

## Variable Reference

All fields inside `ecs_task_definition.configure_logs`:

```hcl
configure_logs = {
  # Master toggle
  enable_fluentbit = bool   # default: false

  # Fluent Bit container image — pin to specific version in production
  fluentbit_image  = string  # default: "amazon/aws-for-fluent-bit:stable"

  # Kinesis stream name in target account
  kinesis_stream_name = string  # e.g. "production-app-logs"

  # Prefix used as ENVIRONMENT env var inside Fluent Bit
  # Drives index naming in OpenSearch: "{log_index_prefix}-YYYY.MM.dd"
  # Defaults to var.environment when not set
  log_index_prefix = string  # e.g. "myproject-production"

  # Architecture B only — ARN of writer role in central logs account
  # null  = Architecture A (same-account, task role writes directly)
  # "arn" = Architecture B (cross-account, task role assumes this role)
  kinesis_cross_account_role_arn = string | null  # default: null

  # Optional S3 ARN of custom fluent-bit.conf
  # null  = AWS default Fluent Bit config (basic, no PII filtering or routing)
  # "arn" = S3-backed config (PII filtering, multi-stream routing, JSON parsing)
  fluentbit_config_s3_arn = string | null  # default: null

  # Legacy static credentials (avoid — use IAM role instead)
  # Leave empty [] for both Architecture A and B
  set_fluentbit_secrets = list(object({ name = string, valueFrom = string }))  # default: []
}
```

---

## Architecture A — Same-Account Kinesis

ECS tasks and Kinesis streams in the **same AWS account**. Fluent Bit uses the ECS task IAM role — no static keys, no cross-account, no Secrets Manager for auth.

```
┌──────────────────────────────────────────────────────────┐
│                    Single AWS Account                    │
│                                                          │
│  ECS Fargate Task                                        │
│  ├── App Container (stdout JSON)                         │
│  └── Fluent Bit sidecar                                  │
│           │  ECS task role credential chain              │
│           │  (auto-rotated STS, no static keys)          │
│           │                                              │
│           │  kinesis:PutRecord                           │
│           ▼                                              │
│  Kinesis Data Streams                                    │
│  ├── {env}-app-logs                                      │
│  ├── {env}-error-logs                                    │
│  └── {env}-audit-logs                                    │
│           │                                              │
│           ▼                                              │
│  Data Prepper / Lambda → OpenSearch                      │
└──────────────────────────────────────────────────────────┘
```

### Module configuration

```hcl
configure_logs = {
  enable_fluentbit               = true
  fluentbit_image                = "amazon/aws-for-fluent-bit:stable"
  kinesis_stream_name            = "${var.environment}-app-logs"
  log_index_prefix               = "${var.project_name}-${var.environment}"
  kinesis_cross_account_role_arn = null    # null = same account
  set_fluentbit_secrets          = []      # no static keys
}
```

### IAM created automatically

The module creates `kinesis_same_account` policy on the task role:
```json
{
  "Effect": "Allow",
  "Action": ["kinesis:PutRecord", "kinesis:PutRecords"],
  "Resource": "arn:aws:kinesis:{region}:{account}:stream/{env}-*"
}
```

Scoped to `{env}-*` streams only — task cannot write to other environment streams.

### Credential chain flow

```
Fluent Bit starts in ECS Fargate
    ↓
AWS SDK checks credential sources (in order):
  1. ENV vars (AWS_ACCESS_KEY_ID) — empty, not set
  2. Config file                  — not present in container
  3. ECS metadata endpoint        — ✅ returns task role credentials
    ↓
Task role has kinesis:PutRecord → writes directly to same-account Kinesis
Credentials auto-rotate every ~15 minutes via STS
```

---

## Architecture B — Cross-Account Kinesis (Central Logs Account)

A dedicated AWS account (`aws-acctn-logs-00`) owns all Kinesis streams, Data Prepper, and OpenSearch. Multiple app accounts write logs to the central account by assuming a Kinesis writer role — no static keys anywhere.

```
┌───────────────────────┐   ┌───────────────────────┐   ┌───────────────────────┐
│  aws-acctn-app-01     │   │  aws-acctn-app-02     │   │  aws-acctn-app-03     │
│  (prod)               │   │  (staging)            │   │  (client B prod)      │
│                       │   │                       │   │                       │
│  ECS Fargate Task     │   │  ECS Fargate Task     │   │  ECS Fargate Task     │
│  └── Fluent Bit       │   │  └── Fluent Bit       │   │  └── Fluent Bit       │
└──────────┬────────────┘   └──────────┬────────────┘   └──────────┬────────────┘
           │                           │                            │
           │     sts:AssumeRole        │                            │
           └───────────────────────────┴────────────────────────────┘
                                       │
                                       ▼
                    ┌──────────────────────────────────────────────┐
                    │         aws-acctn-logs-00 (central)          │
                    │                                              │
                    │  IAM Role: kinesis-cross-account-writer      │
                    │  ├── kinesis:PutRecord on streams            │
                    │  └── Trust: app account root ARNs            │
                    │                    │                         │
                    │                    ▼                         │
                    │  Kinesis Streams (per project/env)           │
                    │  ├── clienta-prod-app-logs                   │
                    │  ├── clienta-staging-app-logs                │
                    │  └── clientb-prod-app-logs                   │
                    │                    │                         │
                    │                    ▼                         │
                    │  Data Prepper (ECS-EC2)                      │
                    │                    │                         │
                    │                    ▼                         │
                    │  OpenSearch (EC2 / ECS-EC2)                  │
                    │  └── Dashboards + Alerting                   │
                    └──────────────────────────────────────────────┘
```

### App account module configuration

```hcl
configure_logs = {
  enable_fluentbit    = true
  fluentbit_image     = "amazon/aws-for-fluent-bit:stable"
  kinesis_stream_name = "clienta-prod-app-logs"   # stream in central account

  # ARN of writer role in aws-acctn-logs-00
  kinesis_cross_account_role_arn = "arn:aws:iam::LOGS_ACCOUNT_ID:role/kinesis-cross-account-writer"

  set_fluentbit_secrets = []  # no static keys
}
```

### IAM created automatically (app account)

The module creates `kinesis_cross_account_assume` policy on the task role:
```json
{
  "Effect": "Allow",
  "Action": "sts:AssumeRole",
  "Resource": "arn:aws:iam::LOGS_ACCOUNT_ID:role/kinesis-cross-account-writer"
}
```

### Central account setup (one-time, outside this module)

```hcl
## In aws-acctn-logs-00

resource "aws_iam_role" "kinesis_writer" {
  name = "kinesis-cross-account-writer"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = {
        AWS = [
          "arn:aws:iam::APP_ACCOUNT_01:root",   # add each app account
          "arn:aws:iam::APP_ACCOUNT_02:root",
          "arn:aws:iam::APP_ACCOUNT_03:root"
        ]
      }
      Action    = "sts:AssumeRole"
      # Optional: restrict to ECS task roles only (not console/human users)
      Condition = {
        StringLike = {
          "aws:PrincipalArn" = "arn:aws:iam::*:role/*-task-role-*"
        }
      }
    }]
  })
}

resource "aws_iam_policy" "kinesis_write" {
  policy = jsonencode({
    Statement = [{
      Effect   = "Allow"
      Action   = ["kinesis:PutRecord", "kinesis:PutRecords"]
      Resource = "arn:aws:kinesis:${var.region}:${var.logs_account_id}:stream/*"
    }]
  })
}
```

### Cross-account credential flow

```
Fluent Bit starts in ECS Fargate (app account)
    ↓
ECS metadata endpoint → task role credentials
    ↓
Fluent Bit calls: sts:AssumeRole
  → arn:aws:iam::LOGS_ACCOUNT:role/kinesis-cross-account-writer
    ↓
STS returns temporary credentials (15-min TTL, auto-renewed)
    ↓
Fluent Bit uses temporary creds: kinesis:PutRecord → central account Kinesis
```

No static keys anywhere. Full audit trail via CloudTrail in both accounts.

### Multi-project stream isolation

Stream name is controlled by `kinesis_stream_name` per module call:

```
aws-acctn-app-01 → kinesis_stream_name = "clienta-prod-app-logs"
aws-acctn-app-02 → kinesis_stream_name = "clienta-staging-app-logs"
aws-acctn-app-03 → kinesis_stream_name = "clientb-prod-app-logs"
```

Adding a new project: add their account to the central role trust policy → they set `kinesis_cross_account_role_arn`. No changes to existing app accounts.

---

## Custom Fluent Bit Config (S3-backed)

When `fluentbit_config_s3_arn` is set, the Fluent Bit sidecar fetches a custom `fluent-bit.conf` from S3 at startup. This enables PII filtering, multi-stream routing, and JSON log parsing — not available with the default AWS Fluent Bit config.

### Module configuration

```hcl
configure_logs = {
  enable_fluentbit        = true
  fluentbit_config_s3_arn = "arn:aws:s3:::my-obs-config-bucket/fluentbit/fluent-bit.conf"
  # ...other fields
}
```

The module creates an `s3:GetObject` policy on the task execution role scoped to this ARN.

### Example `fluent-bit.conf` (Architecture A)

```ini
[SERVICE]
    Flush        1
    Log_Level    warn
    Daemon       off
    Parsers_File parsers.conf
    storage.path /var/log/flb-storage/
    storage.sync normal

[INPUT]
    Name  forward
    Listen 0.0.0.0
    Port  24224

[FILTER]
    Name  record_modifier
    Match *
    Record environment ${ENVIRONMENT}
    Record service     ${ECS_SERVICE_NAME}
    Record cluster     ${ECS_CLUSTER}

[FILTER]
    Name   modify
    Match  *
    Remove password
    Remove token
    Remove secret
    Remove api_key
    Remove authorization

[OUTPUT]
    Name                kinesis_streams
    Match               *
    region              ${KINESIS_REGION}
    stream              ${STREAM}
    # No role_arn — uses ECS task role credential chain automatically
    # role_arn            ${KINESIS_ROLE_ARN}   ← cross-account role assumption
    auto_retry_requests true
    workers             2
```

### Example `fluent-bit.conf` (Architecture B — cross-account)

Same as above, add `role_arn`:

```ini
[OUTPUT]
    Name                kinesis_streams
    Match               *
    region              ${KINESIS_REGION}
    stream              ${STREAM}
    role_arn            ${KINESIS_ROLE_ARN}   # set to "" = no assume (same-account fallback)
    auto_retry_requests true
    workers             2
```

`KINESIS_ROLE_ARN` is injected by the module automatically from `kinesis_cross_account_role_arn`. Empty string when null (Fluent Bit Kinesis plugin ignores empty `role_arn`).

---

## IAM — What Gets Created

The module creates IAM policies conditionally based on `configure_logs` values:

| Policy | Created When | Attached To | Permission |
|---|---|---|---|
| `kinesis_same_account` | `enable_fluentbit=true` AND `cross_account_role=null` | Task role | `kinesis:PutRecord` on `{env}-*` streams |
| `kinesis_cross_account_assume` | `enable_fluentbit=true` AND `cross_account_role` set | Task role | `sts:AssumeRole` on writer role ARN |
| `fluentbit_s3_config` | `enable_fluentbit=true` AND `fluentbit_config_s3_arn` set | Execution role | `s3:GetObject` on config file ARN |

Only one of the first two is created — they are mutually exclusive based on `kinesis_cross_account_role_arn`.

---

## Fluent Bit Environment Variables

Variables injected into the Fluent Bit sidecar container by the module:

| Variable | Value | Source |
|---|---|---|
| `KINESIS_REGION` | Deployment region | `var.aws_region` |
| `STREAM` | Kinesis stream name | `configure_logs.kinesis_stream_name` |
| `ECS_CLUSTER` | Cluster name | `configure_ecs_service.ecs_cluster_name` |
| `ECS_TASK_NAME` | `{env}-{prefix}-{task}` | Module naming convention |
| `ECS_SERVICE_NAME` | `{env}-{prefix}-{task}` | Module naming convention |
| `ENVIRONMENT` | Index prefix | `configure_logs.log_index_prefix` or `var.environment` |
| `KINESIS_ROLE_ARN` | Writer role ARN or `""` | `configure_logs.kinesis_cross_account_role_arn` |

`ECS_TASK_ARN` and `ECS_TASK_DEFINITION` are injected by `enable-ecs-log-metadata: "true"` in the `firelensConfiguration` block — not hardcoded.

---

## Comparison Table

| | Architecture A | Architecture B |
|---|---|---|
| Accounts | Single | Multiple (central logs account) |
| Auth method | ECS task role (direct) | ECS task role → STS AssumeRole |
| Static keys | None | None |
| IAM in app account | `kinesis:PutRecord` | `sts:AssumeRole` |
| IAM in logs account | N/A | Trust policy + `kinesis:PutRecord` |
| Credential rotation | Auto (STS 15-min) | Auto (STS 15-min) |
| Multi-project | No (streams per env, same account) | Yes (streams per project/env, central) |
| Compliance | ✅ | ✅ |
| Setup complexity | Low | Medium (one-time central account setup) |
| When to use | Single-account setup, per-env infra | Multi-account, multi-client, centralized observability |
