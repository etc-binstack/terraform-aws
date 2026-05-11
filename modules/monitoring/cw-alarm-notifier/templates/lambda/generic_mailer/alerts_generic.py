import os
import re
import json
import boto3
import logging
import requests
from datetime import datetime
from string import Template
from pathlib import Path
from sendgrid import SendGridAPIClient
from sendgrid.helpers.mail import Mail
from postmarker.core import PostmarkClient

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

DEFAULT_COLOR = "#007BFF"
DEFAULT_SYMBOL = "ℹ️"
DEFAULT_IMPACT = "Info"

mailServerKeyRaw = os.environ.get("MAIL_SERVER_API_KEY")
mailProvider = os.environ.get("MAIL_PROVIDER", "SendGrid").lower()
teamsWebhookUrl = os.environ.get("TEAMS_WEBHOOK_URL")
enableTeamsNotifications = os.environ.get("ENABLE_TEAMS", "false").lower() == "true"

def determine_impact(state_change, namespace, metric_name):
    if namespace == "AWS/ECS":
        if state_change == "OK -> ALARM":
            return "Warning", "#f5bf42", "⚠️"
        elif state_change == "ALARM -> OK":
            return "Status-OK", "#28a745", "✅"
    elif namespace == "AWS/Route53" and metric_name == "HealthCheckStatus":
        if state_change == "OK -> ALARM":
            return "Critical", "#dc3545", "🚫"
        elif state_change == "ALARM -> OK":
            return "Status-OK", "#28a745", "✅"
    return DEFAULT_IMPACT, DEFAULT_COLOR, DEFAULT_SYMBOL


def convert_datetime_format(iso_str):
    dt = datetime.strptime(iso_str.split(".")[0], "%Y-%m-%dT%H:%M:%S")
    return dt.strftime("%A %d %B, %Y %H:%M:%S UTC")


def get_resource_identifier(dimensions, namespace):
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
    try:
        numbers = re.findall(r'\d+\.?\d*', reason_text)
        return numbers[0] if numbers else "N/A"
    except Exception as e:
        logger.warning(f"Metric extraction failed: {e}")
        return "N/A"


def parse_mail_env_var():
    combined = mailServerKeyRaw
    if not combined:
        raise ValueError("Environment variable MAIL_SERVER_API_KEY is not set")
    if ':' in combined:
        secrets_key, secret_key = map(str.strip, combined.split(':', 1))
    else:
        secrets_key = combined.strip()
        secret_key = "MAIL_API_KEY"
    return secrets_key, secret_key


def get_mail_api_key():
    region_name = os.environ.get("VAULT_REGION", "")
    vault_account_id = os.environ.get("VAULT_ACCOUNT_ID", "")

    secrets_key, secret_key = parse_mail_env_var()
    secret_arn = f"arn:aws:secretsmanager:{region_name}:{vault_account_id}:secret:{secrets_key}"

    logger.info(f"[INFO] Using secret ARN: {secret_arn}")
    logger.info(f"[INFO] Using secret key: {secret_key}")
    logger.info(f"[INFO] Region: {region_name}")

    try:
        client = boto3.client("secretsmanager", region_name=region_name)
        response = client.get_secret_value(SecretId=secret_arn)
        secret_string = response.get("SecretString")
        if not secret_string:
            raise ValueError(f"No SecretString found for ARN: {secret_arn}")

        secret_data = json.loads(secret_string)
        api_key = secret_data.get(secret_key)
        if not api_key:
            raise KeyError(f"Key '{secret_key}' not found in secret data.")

        return api_key.strip()

    except Exception as e:
        logger.error(f"Failed to retrieve API key: {e}")
        raise

def load_html_template(template_data):
    """Generate HTML using string.Template for safer substitution."""

    # Load template filename from environment variable or fallback to default    
    template_file = os.environ.get("MAIL_TEMPLATE", "html_template.html")
    template_path = os.path.join(os.path.dirname(__file__), "__templates__", template_file)    

    current_year = datetime.utcnow().year
    impact = template_data['impact']

    # Configure header styling and icons based on impact level
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

    # Generate description HTML if description is provided
    description_html = ""
    if template_data.get("description") and template_data["description"] != "No description provided.":
        description_html = f"""
            <div class="reason-box" style="margin-top: 15px; padding: 10px; background: #f9f9f9; border-left: 4px solid #ccc; font-style: italic;">
                <strong>Description:</strong> {template_data["description"]}
            </div>
        """

    # Prepare all template variables
    template_vars = {
        'header_bg': header_bg,
        'header_icon': header_icon,
        'impact': impact,
        'symbol': template_data.get('symbol', '⚡'),
        'state_change': template_data.get('state_change', 'N/A'),
        'alarm': template_data.get('alarm', 'Unknown Alarm'),
        'account': template_data.get('account', 'N/A'),
        'region': template_data.get('region', 'N/A'),
        'resource': template_data.get('resource', 'N/A'),
        'datetime': template_data.get('datetime', datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S UTC')),
        'comparisonoperator': template_data.get('comparisonoperator', 'N/A'),
        'threshold': template_data.get('threshold', 'N/A'),
        'namespace': template_data.get('namespace', 'N/A'),
        'metricname': template_data.get('metricname', 'N/A'),
        'reason': template_data.get('reason', 'No reason provided'),
        'description_html': description_html,
        'current_year': current_year,
        'color': template_data.get('color', header_bg)
    }

    try:
        # Resolve template path relative to this file, inside a '__templates__' folder
        template_path = Path(__file__).parent / "__templates__" / template_file

        with open(template_path, 'r', encoding='utf-8') as file:
            template_content = file.read()

        # Use Template class for safer substitution
        template = Template(template_content)
        html = template.safe_substitute(**template_vars)
        return html

    except FileNotFoundError:
        raise FileNotFoundError(f"Template file '{template_file}' not found at {template_path}")
    except Exception as e:
        raise Exception(f"Error processing template: {str(e)}")

# Configure Webhook: for Office 365 (Team's Chennal)
def format_resource_details(template_data):
    """Format resource details in clean line format."""
    resource_text = ""
    
    # Parse the resource string to extract components
    resource = template_data['resource']
    
    if "ECS Service:" in resource:
        # Extract service and cluster from ECS resource
        parts = resource.replace("ECS Service: ", "").split(" (Cluster: ")
        service_name = parts[0] if parts else "Unknown"
        cluster_name = parts[1].replace(")", "") if len(parts) > 1 else "Unknown"
        
        resource_text = f"🎯 **ECS Service:** {service_name}\n🎯 **Cluster:** {cluster_name}"
    
    elif "EC2 Instance:" in resource:
        instance_id = resource.replace("EC2 Instance: ", "")
        resource_text = f"🎯 **EC2 Instance:** {instance_id}"
    
    elif "RDS Instance:" in resource:
        db_id = resource.replace("RDS Instance: ", "")
        resource_text = f"🎯 **RDS Instance:** {db_id}"
    
    elif "Lambda Function:" in resource:
        func_name = resource.replace("Lambda Function: ", "")
        resource_text = f"🎯 **Lambda Function:** {func_name}"
    
    elif "HealthCheck:" in resource:
        health_id = resource.replace("HealthCheck: ", "")
        resource_text = f"🎯 **HealthCheck:** {health_id}"
    
    else:
        resource_text = f"🎯 **Resource:** {resource}"
    
    # Add account, region, and time
    resource_text += f"\n☁️ **Account:** {template_data['account']}"
    resource_text += f"\n🌍 **Region:** {template_data['region']}"
    resource_text += f"\n⏰ **Time:** {template_data['datetime']}"
    
    return resource_text


# Configure Webhook: for Office 365 (Team's Chennal)
def create_teams_adaptive_card(template_data):
    """Create a premium-looking Adaptive Card for Teams notification."""
    
    # Enhanced color and styling mapping
    impact_config = {
        'Critical': {
            'color': 'attention',
            'accent_color': '#FF4444',
            'icon': '🚨',
            'status_text': 'CRITICAL ALERT',
            'bg_color': '#FFE6E6'
        },
        'Warning': {
            'color': 'warning',
            'accent_color': '#FF8C00',
            'icon': '⚠️',
            'status_text': 'WARNING',
            'bg_color': '#FFF4E6'
        },
        'Status-OK': {
            'color': 'good',
            'accent_color': '#28A745',
            'icon': '✅',
            'status_text': 'RESOLVED',
            'bg_color': '#E6F7E6'
        }
    }
    
    config = impact_config.get(template_data['impact'], {
        'color': 'default',
        'accent_color': '#007BFF',
        'icon': 'ℹ️',
        'status_text': 'INFO',
        'bg_color': '#E6F3FF'
    })
    
    # Get current time for "time ago" display
    current_time = datetime.utcnow()
    
    card = {
        "type": "message",
        "attachments": [{
            "contentType": "application/vnd.microsoft.card.adaptive",
            "content": {
                "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
                "type": "AdaptiveCard",
                "version": "1.4",
                "body": [
                    # Header with gradient-like effect
                    {
                        "type": "Container",
                        "style": config['color'],
                        "bleed": True,
                        "items": [
                            {
                                "type": "ColumnSet",
                                "columns": [
                                    {
                                        "type": "Column",
                                        "width": "auto",
                                        "items": [
                                            {
                                                "type": "TextBlock",
                                                "text": config['icon'],
                                                "size": "ExtraLarge",
                                                "spacing": "None"
                                            }
                                        ]
                                    },
                                    {
                                        "type": "Column",
                                        "width": "stretch",
                                        "items": [
                                            {
                                                "type": "TextBlock",
                                                "text": "AWS CloudWatch",
                                                "size": "Small",
                                                "weight": "Lighter",
                                                "color": "Light",
                                                "spacing": "None"
                                            },
                                            {
                                                "type": "TextBlock",
                                                "text": config['status_text'],
                                                "size": "Large",
                                                "weight": "Bolder",
                                                "color": "Light",
                                                "spacing": "None"
                                            }
                                        ]
                                    },
                                    {
                                        "type": "Column",
                                        "width": "auto",
                                        "items": [
                                            {
                                                "type": "TextBlock",
                                                "text": f"🏷️ {template_data['impact']}",
                                                "size": "Small",
                                                "weight": "Bolder",
                                                "color": "Light",
                                                "horizontalAlignment": "Right"
                                            }
                                        ]
                                    }
                                ]
                            }
                        ]
                    },
                    # Main alarm info with enhanced styling + Resource information in a visually appealing layout
                    {
                        "type": "Container",
                        "spacing": "Medium",
                        "items": [
                            {
                                "type": "TextBlock",
                                "text": f"🔄 **{template_data['state_change']}**",
                                "size": "Medium",
                                "weight": "Bolder",
                                "wrap": True,
                                "color": config['color'] if config['color'] != 'default' else 'Default',
                                "spacing": "Small"
                            },
                            {
                                "type": "FactSet",
                                "facts": [
                                    {
                                        "title": "🎯 Resource:",
                                        "value": f"{template_data['resource']}"
                                    },
                                    {
                                        "title": "☁️ Account:",
                                        "value": template_data['account']
                                    },
                                    {
                                        "title": "🌍 Region:",
                                        "value": template_data['region']
                                    },                                 
                                    {
                                        "title": "⏰ Time:",
                                        "value": template_data['datetime']
                                    },
                                    {
                                        "title": "📈 Metric:",
                                        "value": f"{template_data['metricname']} ({template_data['namespace']})"
                                    },                                                                      
                                    {
                                        "title": "🎚️ Threshold/Current:",
                                        "value": f"{template_data['comparisonoperator']} {template_data['threshold']} ({template_data.get('value', 'N/A')})"
                                    },
                                ],
                                "spacing": "Small"
                            }
                        ]
                    },
                    # Reason section with better formatting
                    {
                        "type": "Container",
                        "style": "accent",
                        "spacing": "Medium",
                        "items": [
                            {
                                "type": "TextBlock",
                                "text": "💬 **Detailed Reason**",
                                "weight": "Bolder",
                                "size": "Medium"
                            },
                            {
                                "type": "TextBlock",
                                "text": template_data['reason'],
                                "wrap": True,
                                "spacing": "Small",
                                "size": "Small",
                                "style": "italic"
                            }
                        ]
                    }
                ]
            }
        }]
    }
    
    # Add description section if available
    if template_data.get("description") and template_data["description"] != "No description provided.":
        description_container = {
            "type": "Container",
            "spacing": "Medium",
            "items": [
                {
                    "type": "TextBlock",
                    "text": "📝 **Description**",
                    "weight": "Bolder",
                    "size": "Medium"
                },
                {
                    "type": "TextBlock",
                    "text": template_data['description'],
                    "wrap": True,
                    "spacing": "Small",
                    "size": "Small"
                }
            ]
        }
        card["attachments"][0]["content"]["body"].append(description_container)
    
    # Add footer with AWS branding
    footer_container = {
        "type": "Container",
        "spacing": "Large",
        "separator": True,
        "items": [
            {
                "type": "ColumnSet",
                "columns": [
                    {
                        "type": "Column",
                        "width": "auto",
                        "items": [
                            {
                                "type": "Image",
                                "url": "https://upload.wikimedia.org/wikipedia/commons/9/93/Amazon_Web_Services_Logo.svg",
                                "width": "20px",
                                "height": "20px"
                            }
                        ]
                    },
                    {
                        "type": "Column",
                        "width": "stretch",
                        "items": [
                            {
                                "type": "TextBlock",
                                "text": "AWS CloudWatch Alert System",
                                "size": "Small",
                                "color": "Accent",
                                "weight": "Lighter"
                            }
                        ]
                    },
                    {
                        "type": "Column",
                        "width": "auto",
                        "items": [
                            {
                                "type": "TextBlock",
                                "text": f"🔗 View in Console",
                                "size": "Small",
                                "color": "Accent",
                                "weight": "Lighter"
                            }
                        ]
                    }
                ]
            }
        ]
    }
    card["attachments"][0]["content"]["body"].append(footer_container)
    
    # Add action buttons for quick access
    card["attachments"][0]["content"]["actions"] = [
        {
            "type": "Action.OpenUrl",
            "title": "🔍 View in CloudWatch",
            "url": f"https://console.aws.amazon.com/cloudwatch/home?region={template_data['region']}#alarmsV2:alarm/{template_data['alarm']}"
        },
        {
            "type": "Action.OpenUrl", 
            "title": "📊 View Metrics",
            "url": f"https://console.aws.amazon.com/cloudwatch/home?region={template_data['region']}#metricsV2:graph=~();namespace={template_data['namespace']}"
        }
    ]
    
    return card

# Configure Webhook: for Office 365 (Team's Chennal)
def send_teams_notification(template_data):
    """Send notification to Microsoft Teams via Webhook."""
    try:
        if not teamsWebhookUrl:
            logger.warning("Teams webhook URL not configured. Skipping Teams notification.")
            return
            
        # Create the adaptive card
        card_payload = create_teams_adaptive_card(template_data)
        
        # Send to Teams
        headers = {'Content-Type': 'application/json'}
        response = requests.post(teamsWebhookUrl, json=card_payload, headers=headers, timeout=10)
        
        if response.status_code == 200:
            logger.info("Teams notification sent successfully")
        else:
            logger.error(f"Failed to send Teams notification: {response.status_code} - {response.text}")
            
    except requests.exceptions.RequestException as e:
        logger.error(f"Network error sending Teams notification: {e}")
    except Exception as e:
        logger.error(f"Error sending Teams notification: {e}")


def send_teams_notification_simple_text(template_data):
    """Send a simple text notification to Teams (fallback method)."""
    try:
        if not teamsWebhookUrl:
            logger.warning("Teams webhook URL not configured. Skipping Teams notification.")
            return
            
        # Simple text message for Teams
        message = {
            "text": f"🚨 **AWS CloudWatch Alert**\n\n"
                   f"**{template_data['impact']}**: {template_data['alarm']}\n"
                   f"**State Change**: {template_data['state_change']}\n"
                   f"**Resource**: {template_data['resource']}\n"
                   f"**Account**: {template_data['account']} | **Region**: {template_data['region']}\n"
                   f"**Time**: {template_data['datetime']}\n"
                   f"**Reason**: {template_data['reason']}"
        }
        
        headers = {'Content-Type': 'application/json'}
        response = requests.post(teamsWebhookUrl, json=message, headers=headers, timeout=10)
        
        if response.status_code == 200:
            logger.info("Teams notification (simple text) sent successfully")
        else:
            logger.error(f"Failed to send Teams notification: {response.status_code} - {response.text}")
            
    except Exception as e:
        logger.error(f"Error sending Teams notification: {e}")


def send_alarm_email_sendgrid(template_data):
    try:
        # Use direct API key if provided, otherwise fetch from Secrets Manager
        api_key = mailServerKeyRaw if mailServerKeyRaw and ':' not in mailServerKeyRaw else get_mail_api_key()
        from_email = os.environ.get("EMAIL_FROM_ADDRESS", "cloudwatch-alerts@example.com")
        to_email = os.environ["EMAIL_TO_ADDRESSES"]
        subject = f"[{template_data['impact']}] Alarm: {template_data['alarm']}"
        content = load_html_template(template_data)

        message = Mail(from_email=from_email, to_emails=to_email, subject=subject, html_content=content)
        sg = SendGridAPIClient(api_key)
        response = sg.send(message)
        logger.info(f"Email sent via SendGrid: {response.status_code}")
    except Exception as e:
        logger.error(f"Failed to send email via SendGrid: {e}")


def send_alarm_email_postmark(template_data):
    try:
        # Use direct API key if provided, otherwise fetch from Secrets Manager
        api_key = mailServerKeyRaw if mailServerKeyRaw and ':' not in mailServerKeyRaw else get_mail_api_key()
        from_email = os.environ.get("EMAIL_FROM_ADDRESS", "cloudwatch-alerts@example.com")
        to_email = os.environ["EMAIL_TO_ADDRESSES"]
        subject = f"[{template_data['impact']}] Alarm: {template_data['alarm']}"
        content = load_html_template(template_data)

        postmark = PostmarkClient(server_token=api_key)
        postmark.emails.send(From=from_email, To=to_email, Subject=subject, HtmlBody=content)
        logger.info("Email sent via Postmark successfully.")
    except Exception as e:
        logger.error(f"Failed to send email via Postmark: {e}")


def lambda_handler(event, context):
    logger.info("Received event: %s", json.dumps(event))
    try:
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

        # Send email notification
        if mailProvider == "postmark":
            send_alarm_email_postmark(template_data)
        else:
            send_alarm_email_sendgrid(template_data)
        
        # Send Teams notification if enabled
        if enableTeamsNotifications:
            send_teams_notification(template_data)

    except Exception as e:
        logger.error(f"Error processing alarm: {e}", exc_info=True)
        raise