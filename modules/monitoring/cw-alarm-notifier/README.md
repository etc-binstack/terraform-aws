# Example file:
```yml
module "cloudwatch_ses_alerts" {
  source = "../modules/lambda-alert-ses" # path to your module

  enable_module = true
  region        = "us-east-1"
  environment   = "dev"

  lambda_function = {
    create        = true
    function_name = "cw-ses-alert"
    role_name     = "cw-ses-lambda-role"
    runtime       = "python3.11"
    timeout       = 10
  }

  ses_configuration = {
    template_name = "CriticalAlertTemplate"
    email_from    = "alerts@example.com"
    email_to      = "devops@example.com"
    email_cc      = "teamlead@example.com"
    email_reply_to = "noreply@example.com"
  }

  common_tags = {
    Project     = "CloudWatchAlerts"
    Environment = "dev"
    Owner       = "PlatformTeam"
  }
}

```


## Test lambda role can access secretmanager secret (cross account)

Since the role is a Lambda execution role, you can't directly run CLI commands as that role, but you can assume that role using AWS STS from your CLI user (if you have permission), and then run the command with those assumed credentials.

* Here’s the step-by-step:

### Step 1: Assume the Lambda role from CLI
```bash
aws sts assume-role \
  --role-arn arn:aws:iam::ACCOUNT_ID:role/LAMBDA_EXECUTION_ROLE_NAME \
  --role-session-name testLambdaRoleSession
```
#### Get error by above command (change inside lambda role):
```yml
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com",
        "AWS": "arn:aws:iam::789501569648:user/sysadmin"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

```yml
"Principal": {
  "Service": "lambda.amazonaws.com",
  "AWS": "arn:aws:iam::789501569648:root"
}
```


* This outputs temporary credentials:
```json
{
  "Credentials": {
    "AccessKeyId": "ASIA...",
    "SecretAccessKey": "SECRET...",
    "SessionToken": "TOKEN...",
    "Expiration": "..."
  }
}
```

### Step 2: Export temporary creds to environment variables
```bash
export AWS_ACCESS_KEY_ID=ASIA...
export AWS_SECRET_ACCESS_KEY=SECRET...
export AWS_SESSION_TOKEN=TOKEN...
#(Replace with values from the output)
```
### Step 3: Run your secretsmanager command with those creds
```bash
aws secretsmanager get-secret-value \
  --secret-id dev/website/sharedSecretKeys-umXvBl \
  --region us-east-1 \
  --query SecretString --output text | jq '.sgApiKey'
```
### Step 4: When done, unset the temporary creds
```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
```
#### Note:
* Your current IAM user/role needs permission to sts:AssumeRole on the Lambda execution role.

* The Lambda execution role must have permission to read that secret from Secrets Manager.

```powershell
# Option 1: Download the jq executable manually
# Go to the jq official releases page:
# https://github.com/stedolan/jq/releases
# Download the Windows binary, for example:
# jq-win64.exe (64-bit)

# Option 2: Using winget (Windows Package Manager)
# If you have Windows 10 (version 1809 or later) or Windows 11, you can use winget:
winget install jq  # optional: choco install jq
jq --version

#Multiple packages found matching input criteria. Please refine the input.
#Name           Id           Source
#-----------------------------------
#JQuery 9NBLGGH4P48H msstore
#jq             jqlang.jq    winget
#Multiple packages found for: jq

winget install --id jqlang.jq
```