[
  {
    "essential": true,
    "name": "fluentbit-logrouter",
    "image": "${fluentbit_image}",
    "firelensConfiguration": {
      "type": "fluentbit",
      "options": {
        "enable-ecs-log-metadata": "true"
        %{ if fluentbit_config_s3_arn != "" ~},
        "config-file-type":  "s3",
        "config-file-value": "${fluentbit_config_s3_arn}"
        %{ endif ~}
      }
    },
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-create-group":  "true",
        "awslogs-group":         "/ecs/${environment}-${ecs_cluster_prefix}-${task_name}",
        "awslogs-region":        "${aws_region}",
        "awslogs-stream-prefix": "fluentbit"
      }
    },
    "environment": ${set_fluentbit_environment},
    "secrets": ${set_fluentbit_secrets},
    "mountPoints": [],
    "portMappings": [],
    "volumesFrom": [],
    "systemControls": [],
    "user": "0"
  }
]
