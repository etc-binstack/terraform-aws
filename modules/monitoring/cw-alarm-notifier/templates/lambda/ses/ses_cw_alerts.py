import json
import boto3
import os
import logging
import re
from datetime import datetime
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

def determine_impact(state_change, namespace, metric_name):
    if namespace == "AWS/ECS":
        if state_change == "OK -> ALARM":
            # return "Warning", "#f5bf42", "\u26A0"  # warning symbol
            return "Warning", "#f5bf42", "⚠️"
        elif state_change == "ALARM -> OK":
            return "Status-OK", "green", "\u2705"  # check mark
    elif namespace == "AWS/Route53" and metric_name == "HealthCheckStatus":
        if state_change == "OK -> ALARM":
            return "Critical", "red", "\u26D4"  # no entry
        elif state_change == "ALARM -> OK":
            return "Status-OK", "green", "\u2705"
    # return "Info", "gray", "\u2139"  # info symbol
    return "Info", "#007BFF", "ℹ️"

def convert_datetime_format(iso_str):
    dt = datetime.strptime(iso_str.split(".")[0], "%Y-%m-%dT%H:%M:%S")
    return dt.strftime("%A %d %B, %Y %H:%M:%S UTC")

def create_ses_template_if_not_exists(ses_client, template_name):
    try:
        ses_client.get_template(TemplateName=template_name)
        logger.info(f"Template '{template_name}' already exists.")
        return True
    except ClientError as e:
        if e.response['Error']['Code'] == 'TemplateDoesNotExist':
            logger.info(f"Template '{template_name}' does not exist. Creating...")

            template = {
                'TemplateName': template_name,
                'SubjectPart': '{{impact}} Alarm on {{alarm}}',
                'TextPart': (
                    "ALERT NOTIFICATION\n\n"
                    "State Change: {{state_change}}\n"
                    "Alarm Name: {{alarm}}\n"
                    "Account: {{account}} ({{region}})\n"
                    "Resource: {{resource}}\n"
                    "Date/Time: {{datetime}}\n"
                    "Reason: Current value {{value}} is {{comparisonoperator}} {{threshold}}\n"
                    "Description: {{description}}\n"
                    "Monitored Metric: Namespace: {{namespace}}, Name: {{metricname}}"
                ),
                'HtmlPart': (
                    "<h2><span style='color: {{color}};'>{{symbol}}</span> Amazon CloudWatch Alarm Triggered</h2>"
                    "<table style='width: 70%; border-collapse: collapse;' border='1' cellpadding='5'>"
                    "<tr><td><b>Impact</b></td><td style='color: {{color}};'><b>{{impact}}</b></td></tr>"
                    "<tr><td><b>State Change</b></td><td>{{state_change}}</td></tr>"
                    "<tr><td><b>Alarm Name</b></td><td>{{alarm}}</td></tr>"
                    "<tr><td><b>Account</b></td><td>{{account}} ({{region}})</td></tr>"
                    "<tr><td><b>Resource</b></td><td>{{resource}}</td></tr>"
                    "<tr><td><b>Date-Time</b></td><td>{{datetime}}</td></tr>"
                    "<tr><td><b>Reason</b></td><td>Current value <b>{{value}}</b> is {{comparisonoperator}} <b>{{threshold}}</b></td></tr>"
                    "<tr><td><b>Description</b></td><td>{{description}}</td></tr>"
                    "<tr><td><b>Monitored Metric</b></td><td>Namespace: {{namespace}}, Name: {{metricname}}</td></tr>"
                )
            }

            ses_client.create_template(Template=template)
            logger.info(f"Template '{template_name}' created successfully.")
            return True
        else:
            logger.error(f"Error checking/creating template: {e}")
            raise

def get_resource_identifier(dimensions, namespace):
    extract = lambda key: next((d['value'] for d in dimensions if d['name'] == key), None)
    if namespace == "AWS/EC2":
        return f"EC2 Instance: {extract('InstanceId')}"
    elif namespace == "AWS/ECS":
        svc = extract('ServiceName')
        cluster = extract('ClusterName')
        return f"ECS Service: {svc} (Cluster: {cluster})" if svc and cluster else f"ECS Service: {svc or cluster}"
    elif namespace == "AWS/RDS":
        return f"RDS Instance: {extract('DBInstanceIdentifier')}"
    elif namespace == "AWS/Lambda":
        return f"Lambda Function: {extract('FunctionName')}"
    elif namespace == "AWS/Route53":
        return f"HealthCheck: {extract('HealthCheckId')}"
    else:
        return f"{namespace} - " + ", ".join([f"{d['name']}: {d['value']}" for d in dimensions])

def extract_metric_value(reason_text):
    try:
        numbers = re.findall(r'\d+\.?\d*', reason_text)
        return numbers[0] if numbers else "N/A"
    except Exception as e:
        logger.warning(f"Metric extraction failed: {e}")
        return "N/A"

def lambda_handler(event, context):
    logger.info(f"Received event: {json.dumps(event)}")

    try:
        message = json.loads(event['Records'][0]['Sns']['Message'])
    except Exception as e:
        logger.error(f"Failed to parse SNS message: {e}")
        raise

    alarm_name = message.get('AlarmName')
    aws_account_id = message.get('AWSAccountId')
    region = message.get('Region')
    threshold = message['Trigger']['Threshold']
    reason = message.get('NewStateReason', '')
    datetime_utc = convert_datetime_format(message.get('StateChangeTime', ''))
    dimensions = message['Trigger']['Dimensions']
    comparison = message['Trigger']['ComparisonOperator']
    namespace = message['Trigger']['Namespace']
    metric_name = message['Trigger']['MetricName']
    state_change = message.get('OldStateValue') + " -> " + message.get('NewStateValue')
    description = message.get('AlarmDescription', 'No description provided.')

    impact, color, symbol = determine_impact(state_change, namespace, metric_name)

    metric_value = extract_metric_value(reason)
    resource = get_resource_identifier(dimensions, namespace)

    template_name = os.environ['SES_TEMPLATE']
    source_email = os.environ['EMAIL_FROM_ADDRESS']
    to_email = os.environ['EMAIL_TO_ADDRESSES']
    cc_email = os.environ.get('EMAIL_CC_ADDRESSES', '')
    reply_to = os.environ.get('EMAIL_REPLY_TO_ADDRESSES', '')

    ses = boto3.client('ses')

    try:
        create_ses_template_if_not_exists(ses, template_name)
    except Exception as e:
        logger.error(f"SES template check/create failed: {e}")
        raise

    template_data = {
        "alarm": alarm_name,
        "reason": reason,
        "account": aws_account_id,
        "region": region,
        "datetime": datetime_utc,
        "resource": resource,
        "value": metric_value,
        "comparisonoperator": comparison,
        "threshold": str(threshold),
        "impact": impact,
        "color": color,
        "symbol": symbol,
        "description": description,
        "namespace": namespace,
        "metricname": metric_name,
        "state_change": state_change
    }

    logger.info(f"Template Data: {template_data}")

    try:
        ses.send_templated_email(
            Source=source_email,
            Destination={
                'ToAddresses': [to_email],
                'CcAddresses': [cc_email] if cc_email else []
            },
            ReplyToAddresses=[reply_to] if reply_to else [],
            Template=template_name,
            TemplateData=json.dumps(template_data)
        )
        logger.info(f"Email sent to {to_email}")
    except Exception as e:
        logger.error(f"Failed to send templated email: {e}")
        raise

    return {
        'statusCode': 200,
        'body': json.dumps("Email sent successfully.")
    }
