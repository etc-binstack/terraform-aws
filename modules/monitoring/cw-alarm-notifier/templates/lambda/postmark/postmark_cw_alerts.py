import os
import re
import json
import boto3
import logging
from datetime import datetime
from postmarker.core import PostmarkClient

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Constants
DEFAULT_COLOR = "#007BFF"
DEFAULT_SYMBOL = "ℹ️"
DEFAULT_IMPACT = "Info"

# Set environment variable once globally
postMarkApiKey = os.environ.get("POSTMARK_API_KEY")

def determine_impact(state_change, namespace, metric_name):
    """Determine the impact level and styling based on CloudWatch namespace and state."""
    if namespace == "AWS/ECS":
        if state_change == "OK -> ALARM":
            return "Warning", "#f5bf42", "⚠️"
        elif state_change == "ALARM -> OK":
            return "Status-OK", "#28a745", "✅"  # check mark
    elif namespace == "AWS/Route53" and metric_name == "HealthCheckStatus":
        if state_change == "OK -> ALARM":
            return "Critical", "#dc3545", "🚫"  # no entry
        elif state_change == "ALARM -> OK":
            return "Status-OK", "#28a745", "✅"
    return DEFAULT_IMPACT, DEFAULT_COLOR, DEFAULT_SYMBOL

def convert_datetime_format(iso_str):
    """Convert ISO date format to human-readable string."""
    dt = datetime.strptime(iso_str.split(".")[0], "%Y-%m-%dT%H:%M:%S")
    return dt.strftime("%A %d %B, %Y %H:%M:%S UTC")

def get_resource_identifier(dimensions, namespace):
    """Extract human-readable identifier based on resource namespace."""
    extract = lambda key: next((d['value'] for d in dimensions if d['name'] == key), None)
    match namespace:
        case "AWS/EC2":
            return f"EC2 Instance: {extract('InstanceId')}"
        case "AWS/ECS":
            svc = extract('ServiceName')
            cluster = extract('ClusterName')
            return f"ECS Service: {svc} (Cluster: {cluster})" if svc and cluster else f"ECS Service: {svc or cluster}"
        case "AWS/RDS":
            return f"RDS Instance: {extract('DBInstanceIdentifier')}"
        case "AWS/Lambda":
            return f"Lambda Function: {extract('FunctionName')}"
        case "AWS/Route53":
            return f"HealthCheck: {extract('HealthCheckId')}"
        case _:
            return f"{namespace} - " + ", ".join([f"{d['name']}: {d['value']}" for d in dimensions])

def extract_metric_value(reason_text):
    """Extract numeric value from alarm reason text."""
    try:
        numbers = re.findall(r'\d+\.?\d*', reason_text)
        return numbers[0] if numbers else "N/A"
    except Exception as e:
        logger.warning(f"Metric extraction failed: {e}")
        return "N/A"

def create_html_template(template_data):
    """Generate enhanced HTML content for CloudWatch alarm email."""
    current_year = datetime.utcnow().year
    impact = template_data['impact']

    # Determine header background and icon
    header_bg = {
        'Critical': '#d9534f',
        'Warning': '#d9b04f',
        'Status-OK': '#4fd982'
    }.get(impact, '#4f6fd9')

    header_icon = {
        'Critical': '🚨',
        'Warning': '⚠️',
        'Status-OK': '✅'
    }.get(impact, 'ℹ️')

    # Description block if provided
    description_html = ""
    if template_data.get("description") and template_data["description"] != "No description provided.":
        description_html = f"""
            <div class="reason-box" style="margin-top: 15px; padding: 10px; background: #f9f9f9; border-left: 4px solid #ccc; font-style: italic;">
                <strong>Description:</strong> {template_data["description"]}
            </div>
        """

    html = f"""<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>CloudWatch Alarm Notification</title>
<style>
    body {{
        font-family: 'Segoe UI', Tahoma, sans-serif;
        margin: 0;
        padding: 0;
        background: #f4f6f9;
        color: #333;
    }}
    .container {{
        max-width: 700px;
        margin: 20px auto;
        background: #fff;
        border-radius: 10px;
        box-shadow: 0 2px 10px rgba(0,0,0,0.1);
        overflow: hidden;
    }}
    .header {{
        background: {header_bg};
        color: #fff;
        padding: 20px 25px;
        text-align: center;

    }}
    .header h1 {{
        margin: 0;
        font-size: 22px;
        display: flex;
        align-items: center;
        justify-content: center;
        gap: 10px;
    }}
    .icon {{
        font-size: 30px;
    }}
    .badge {{
        background: {template_data['color']};
        color: #fff;
        padding: 5px 12px;
        border-radius: 20px;
        display: inline-block;
        font-size: 12px;
        font-weight: bold;
        text-transform: uppercase;
        margin: 10px 0;
    }}
    .content {{
        padding: 20px 25px;
        font-size: 14px;
    }}
    .table {{
        width: 100%;
        border-collapse: collapse;
        margin-top: 10px;
    }}
    .table th, .table td {{
        padding: 10px;
        text-align: left;
        border-bottom: 1px solid #e0e0e0;
        vertical-align: top;
    }}
    .table th {{
        background: #f0f2f5;
        text-transform: uppercase;
        font-size: 12px;
        font-weight: 600;
        color: #555;
        width: 40%;
    }}
    .table td strong {{
        color: #000;
    }}
    .reason {{
        margin-top: 15px;
        background: #fff8e1;
        border-left: 5px solid #fbc02d;
        padding: 10px 15px;
        font-style: italic;
        border-radius: 4px;
    }}
    .footer {{
        background: #f1f3f5;
        text-align: center;
        font-size: 12px;
        color: #888;
        padding: 15px;
        border-top: 1px solid #dee2e6;
    }}
    .footer a {{
        color: #007bff;
        text-decoration: none;
    }}
</style>
</head>
<body>
<div class="container">
    <!-- Dynamic Header (insert here) -->
    <div class="header" style="background: {header_bg}; color: white; padding: 30px 20px; text-align: center;">
        <h1 style="margin: 0; font-size: 28px; font-weight: 700;">
            <span class="icon" style="font-size: 40px; display: block; margin-bottom: 10px;">{header_icon}</span>
            CloudWatch Alarm Triggered
        </h1>
    </div>
    <div class="content">
        <div class="badge">{template_data['symbol']} {impact}</div>
        <table class="table">
            <tr><th>State Change</th><td><strong>{template_data['state_change']}</strong></td></tr>
            <tr><th>Alarm Name</th><td>{template_data['alarm']}</td></tr>
            <tr><th>Account & Region</th><td>{template_data['account']} ({template_data['region']})</td></tr>
            <tr><th>Resource</th><td>{template_data['resource']}</td></tr>
            <tr><th>Date & Time</th><td>{template_data['datetime']}</td></tr>
            <tr><th>Comparison</th><td>{template_data['comparisonoperator']} <strong>{template_data['threshold']}</strong></td></tr>
            <tr><th>Metric</th><td>Namespace: <strong>{template_data['namespace']}</strong><br>Name: <strong>{template_data['metricname']}</strong></td></tr>
        </table>
        <div class="reason"><strong>Reason:</strong> {template_data['reason']}</div>
        {description_html}
        <p style="margin-top: 20px; color: #555;">
            📋 <strong>Next Steps:</strong> Please review the AWS CloudWatch console for metrics, logs, and corrective actions.
        </p>
    </div>
    <div class="footer">
        <p>© {current_year} AWS CloudWatch Monitoring System</p>
        <p>This is an automated notification. Please do not reply.</p>
    </div>
</div>
</body>
</html>"""
    return html

def parse_postmark_env_var():
    combined = postMarkApiKey
    if not combined:
        raise ValueError("Environment variable POSTMARK_API_KEY is not set")

    # Split on first colon, and strip whitespace from parts
    if ':' in combined:
        secrets_key, postmark_api_key = map(str.strip, combined.split(':', 1))
    else:
        # If no colon, treat entire string as secret name, default key
        secrets_key = combined.strip()
        postmark_api_key = "POSTMARK_API_KEY"

    return secrets_key, postmark_api_key

def get_postmark_api_key():
    """Fetch the Postmark API key from cross-account Secrets Manager.
    Reads VAULT_REGION and VAULT_ACCOUNT_ID from Lambda environment variables
    injected by Terraform (crossaccount_vault configuration).
    """
    region_name = os.environ.get("VAULT_REGION", "")
    vault_account_id = os.environ.get("VAULT_ACCOUNT_ID", "")

    parse_result = parse_postmark_env_var()
    secrets_key = parse_result[0]
    postmark_api_key = parse_result[1]

    secret_arn = f"arn:aws:secretsmanager:{region_name}:{vault_account_id}:secret:{secrets_key}"
    secret_key = postmark_api_key

    print(f"[INFO] Using secret ARN: {secret_arn}")
    print(f"[INFO] Using secret key: {secret_key}")
    print(f"[INFO] Region: {region_name}")

    try:
        client = boto3.client("secretsmanager", region_name=region_name)
        response = client.get_secret_value(SecretId=secret_arn)

        secret_string = response.get("SecretString")
        if not secret_string:
            raise ValueError(f"No SecretString found for ARN: {secret_arn}")

        print(f"[DEBUG] Retrieved secret string (first 100 chars): {secret_string[:11]}...")

        secret_data = json.loads(secret_string)
        print(f"[DEBUG] Available keys: {list(secret_data.keys())}")

        api_key = secret_data.get(secret_key)
        if not api_key:
            raise KeyError(f"Key '{secret_key}' not found in secret data.")

        print("[INFO] Successfully retrieved PostMark API key.")
        return api_key.strip()

    except Exception as e:
        print(f"[ERROR] Failed to retrieve PostMark API key: {e}")
        raise

def send_alarm_email_postmark(template_data):
    """Send email using PostMark with rendered template."""
    try:
        if postMarkApiKey and postMarkApiKey.startswith(("86b3000")):
            postmark_api_key = postMarkApiKey  # call api_key direct from Enviroment variable
            logger.info(f"[INFO] PostMark API key found directly in env: {postmark_api_key[:11]}***")
        else:
            postmark_api_key = get_postmark_api_key() # call from function def get_postmark_api_key():
            logger.info(f"[INFO] PostMark API key retrieved from Secrets Manager: {postmark_api_key[:11]}***")

        from_email = os.environ.get("EMAIL_FROM_ADDRESS", "cloudwatch-alerts@example.com")
        to_email = os.environ["EMAIL_TO_ADDRESSES"]

        subject = f"[{template_data['impact']}] Alarm: {template_data['alarm']}"
        content = create_html_template(template_data)

        postmark = PostmarkClient(server_token=postmark_api_key)
        postmark.emails.send(
            From=from_email, 
            To=to_email, 
            Subject=subject, 
            HtmlBody=content
        )
        logger.info("Email sent via Postmark successfully.")
    except Exception as e:
        logger.error(f"Failed to send email via Postmark: {e}")


def lambda_handler(event, context):
    logger.info("Received event: %s", json.dumps(event))
    
    try:
        # Extract details from CloudWatch alarm event
        message = json.loads(event['Records'][0]['Sns']['Message'])
        state_change = f"{message['OldStateValue']} -> {message['NewStateValue']}"
        namespace = message['Trigger']['Namespace']
        metric_name = message['Trigger']['MetricName']
        dimensions = message['Trigger']['Dimensions']

        impact, color, symbol = determine_impact(state_change, namespace, metric_name)

        template_data = {
            "impact": impact,
            "color": color,
            "symbol": symbol,
            "state_change": state_change,
            "alarm": message['AlarmName'],
            "account": message['AWSAccountId'],
            "region": message['Region'],
            "resource": get_resource_identifier(dimensions, namespace),
            "datetime": convert_datetime_format(message['StateChangeTime']),
            "value": extract_metric_value(message['NewStateReason']),
            "comparisonoperator": message['Trigger']['ComparisonOperator'],
            "threshold": message['Trigger']['Threshold'],
            "namespace": namespace,
            "metricname": metric_name,
            "reason": message['NewStateReason'],
            "description": message.get('AlarmDescription', 'No description provided.')
        }

        send_alarm_email_postmark(template_data)
        logger.info("Email sent successfully.")

    except Exception as e:
        logger.error(f"Error processing alarm: {e}", exc_info=True)
        raise
