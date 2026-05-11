## ==================================================
## ECS: Security Group (New version)
## ==================================================
resource "aws_security_group" "sgp" {
  count = var.enable_module ? 1 : 0

  name        = "${var.environment}-${var.ecs_cluster_prefix}-${local.task_definition.task_name}-EcsContainer-Sgp"
  description = "Used by ECS services, ${local.task_definition.task_name} containers"
  vpc_id      = local.network.vpc_id

  tags = merge(
    var.common_tags,
    {
      Name = "${var.environment}-${var.ecs_cluster_prefix}-${local.task_definition.task_name}-EcsContainer"
    }
  )
}

## Egress: allow all
resource "aws_security_group_rule" "e01" {
  count = var.enable_module ? 1 : 0

  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "Fargate-Containers to ALL"
  security_group_id = aws_security_group.sgp[0].id
}

# Ingress: from VPC CIDR
resource "aws_security_group_rule" "i01" {
  count = var.enable_module ? 1 : 0

  type              = "ingress"
  from_port         = local.host_port
  to_port           = local.host_port
  protocol          = "tcp"
  cidr_blocks       = [local.network.vpc_cidr]
  description       = "VPC-CIDR to Fargate-Containers"
  security_group_id = aws_security_group.sgp[0].id
}

# Ingress: from Peering CIDRs
resource "aws_security_group_rule" "i02" {
  count = var.enable_module && length(try(local.peering_rules.peering_cidrs, [])) > 0 ? 1 : 0

  type              = "ingress"
  from_port         = local.host_port
  to_port           = local.host_port
  protocol          = "tcp"
  cidr_blocks       = try(local.peering_rules.peering_cidrs, [])
  description       = "Peering VPC-CIDRs to Fargate-Containers"
  security_group_id = aws_security_group.sgp[0].id
}

# Ingress: Custom rules
resource "aws_security_group_rule" "ci03" {
  for_each = var.enable_module ? try(local.custom_rules.create_rules, {}) : {}

  type              = "ingress"
  from_port         = each.value.from_port
  to_port           = each.value.to_port
  protocol          = each.value.protocol
  cidr_blocks       = each.value.cidr_blocks
  description       = each.value.description
  security_group_id = aws_security_group.sgp[0].id
}
