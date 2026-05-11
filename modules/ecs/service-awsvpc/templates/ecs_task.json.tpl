[
  {
    "name": "${environment}-${ecs_cluster_prefix}-${task_name}",
    "image": "${container_image}",
    "cpu": ${fargate_cpu},
    "memory": ${fargate_memory},
    "networkMode": "awsvpc",
    "logConfiguration": {
      "logDriver": "${enable_fluentbit ? "awsfirelens" : "awslogs"}",
      "options": ${enable_fluentbit ?
        jsonencode({}) :
        jsonencode({
          "awslogs-group":         "/ecs/${environment}-${ecs_cluster_prefix}-${task_name}",
          "awslogs-region":        "${aws_region}",
          "awslogs-stream-prefix": "ecs"
        })}
    },
    "secrets": ${enable_secrets ? set_secrets : "[]"},
    "environment": ${enable_environment ? set_environment : "[]"},
    "mountPoints": ${enable_efs ? set_mount_points : "[]"},
    "portMappings": [
      {
        "containerPort": ${container_port},
        "hostPort": ${host_port},
        "name": "${task_name}"
      }
    ]
    %{ if enable_healthcheck ~},
    "healthCheck": ${healthcheck_config}%{ endif ~},
    "stopTimeout": ${stop_timeout}
    %{ if enable_command ~},
    "command": ${command_config}%{ endif ~}
    %{ if enable_entrypoint ~},
    "entryPoint": ${entrypoint_config}%{ endif ~}
  }
]
