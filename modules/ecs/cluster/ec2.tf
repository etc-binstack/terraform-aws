## =========================================
## EC2 Capacity Provider
## Required for: bridge mode, GPU instances, high-density task packing
## All resources are count-gated on var.capacity_providers.ec2.enabled
## =========================================

## ECS-optimized Amazon Linux 2 AMI — resolved via SSM when ami_id not provided
data "aws_ssm_parameter" "ecs_optimized_ami" {
  count = var.enable_module && local.ec2.enabled && local.ec2.ami_id == null ? 1 : 0
  name  = "/aws/service/ecs/optimized-ami/amazon-linux-2/recommended/image_id"
}

## IAM: EC2 instance role — allows instances to register with ECS cluster
data "aws_iam_policy_document" "ec2_assume_role" {
  count = var.enable_module && local.ec2.enabled ? 1 : 0
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2_instance_role" {
  count              = var.enable_module && local.ec2.enabled ? 1 : 0
  name               = "${local.ecs_cluster_name}-ec2-instance-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role[0].json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "ec2_ecs_agent" {
  count      = var.enable_module && local.ec2.enabled ? 1 : 0
  role       = aws_iam_role.ec2_instance_role[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  count      = var.enable_module && local.ec2.enabled ? 1 : 0
  role       = aws_iam_role.ec2_instance_role[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

## Additional caller-supplied policies
resource "aws_iam_role_policy_attachment" "ec2_additional" {
  for_each   = var.enable_module && local.ec2.enabled ? toset(local.ec2.additional_iam_policy_arns) : []
  role       = aws_iam_role.ec2_instance_role[0].name
  policy_arn = each.value
}

resource "aws_iam_instance_profile" "ec2" {
  count = var.enable_module && local.ec2.enabled ? 1 : 0
  name  = "${local.ecs_cluster_name}-ec2-instance-profile"
  role  = aws_iam_role.ec2_instance_role[0].name
  tags  = var.tags
}

## Launch Template — EC2 instance configuration
resource "aws_launch_template" "ec2" {
  count         = var.enable_module && local.ec2.enabled ? 1 : 0
  name_prefix   = "${local.ecs_cluster_name}-"
  image_id      = local.ec2_ami_id
  instance_type = local.ec2.instance_type
  key_name      = local.ec2.key_name

  iam_instance_profile {
    arn = aws_iam_instance_profile.ec2[0].arn
  }

  user_data = local.ec2_user_data

  monitoring {
    enabled = true
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"   # IMDSv2 enforced
    http_put_response_hop_limit = 2            # 2 needed for containers to reach IMDS
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.tags, {
      Name        = "${local.ecs_cluster_name}-ec2"
      ClusterName = local.ecs_cluster_name
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(var.tags, {
      Name        = "${local.ecs_cluster_name}-ec2-volume"
      ClusterName = local.ecs_cluster_name
    })
  }

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

## Auto Scaling Group — EC2 fleet management
resource "aws_autoscaling_group" "ec2" {
  count               = var.enable_module && local.ec2.enabled ? 1 : 0
  name_prefix         = "${local.ecs_cluster_name}-"
  min_size            = local.ec2.min_size
  max_size            = local.ec2.max_size
  desired_capacity    = local.ec2.desired_capacity
  vpc_zone_identifier = local.ec2.vpc_zone_identifier

  launch_template {
    id      = aws_launch_template.ec2[0].id
    version = "$Latest"
  }

  ## Required for ECS managed scaling to work
  protect_from_scale_in = true

  tag {
    key                 = "Name"
    value               = "${local.ecs_cluster_name}-ec2-asg"
    propagate_at_launch = true
  }

  tag {
    key                 = "AmazonECSManaged"
    value               = "true"
    propagate_at_launch = true
  }

  dynamic "tag" {
    for_each = var.tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    ignore_changes = [desired_capacity]   # ECS managed scaling controls desired_capacity
  }
}

## ECS Capacity Provider — links ASG to ECS cluster
resource "aws_ecs_capacity_provider" "ec2" {
  count = var.enable_module && local.ec2.enabled ? 1 : 0
  name  = "${local.ecs_cluster_name}-ec2-cp"

  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.ec2[0].arn
    managed_termination_protection = "ENABLED"

    managed_scaling {
      status                    = local.ec2.managed_scaling_enabled ? "ENABLED" : "DISABLED"
      target_capacity           = local.ec2.managed_scaling_target
      minimum_scaling_step_size = 1
      maximum_scaling_step_size = 100
    }
  }

  tags = merge(var.tags, {
    ClusterName = local.ecs_cluster_name
  })
}
