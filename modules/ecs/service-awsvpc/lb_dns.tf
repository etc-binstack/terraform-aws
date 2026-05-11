## ============================================================
## Load Balancer: Target Groups, Listener Rules, DNS Records
## Supports: ALB, NLB, multiple LBs per service
## Driven by: var.configure_load_balancers (list → for_each map)
## ============================================================

## random_integer scoped to ALB entries only
## NLB listener rules use priority = null (AWS auto-assigns)
resource "random_integer" "priority" {
  for_each = var.enable_module ? { for k, v in local.lb_map : k => v if v.type == "alb" } : {}
  min      = 100
  max      = 901
}

## ============================================================
## Target Groups (one per LB entry)
## ALB/NLB split fields handled via type-conditional ternary
## ============================================================
resource "aws_lb_target_group" "tg" {
  for_each    = var.enable_module ? local.lb_map : {}
  name        = "${var.environment}-${var.ecs_cluster_prefix}-${each.key}"
  port        = each.value.container_port
  protocol    = each.value.target_group.protocol
  vpc_id      = local.network.vpc_id
  target_type = each.value.target_group.target_type

  health_check {
    protocol            = each.value.target_group.health_check.protocol
    interval            = each.value.target_group.health_check.interval
    timeout             = each.value.target_group.health_check.timeout
    healthy_threshold   = each.value.target_group.health_check.healthy_threshold
    unhealthy_threshold = each.value.target_group.health_check.unhealthy_threshold

    # path and matcher: ALB only, or NLB with HTTP/HTTPS health check
    # Not valid for NLB with TCP protocol health check
    path    = (each.value.type == "nlb" && each.value.target_group.health_check.protocol == "TCP") ? null : each.value.target_group.health_check.path
    matcher = (each.value.type == "nlb" && each.value.target_group.health_check.protocol == "TCP") ? null : each.value.target_group.health_check.matcher
  }

  deregistration_delay = each.value.target_group.deregistration_delay

  # slow_start and load_balancing_algorithm_type: ALB only
  slow_start                    = each.value.type == "alb" ? each.value.target_group.slow_start : null
  load_balancing_algorithm_type = each.value.type == "alb" ? each.value.target_group.load_balancing_algorithm_type : null

  # proxy_protocol_v2: NLB only
  proxy_protocol_v2 = each.value.type == "nlb" ? true : null

  tags = merge(
    var.common_tags,
    { Name = "${var.environment}-${var.ecs_cluster_prefix}-${each.key}" }
  )
}

## ============================================================
## Listener Rules (only for LBs with routing enabled + ARN set)
## ALB/NLB split:
##   priority   — ALB: explicit or random. NLB: null (auto-assigned)
##   conditions — ALB only. NLB does not support host_header/path conditions
## ============================================================
resource "aws_lb_listener_rule" "rule" {
  for_each     = var.enable_module ? local.lb_with_routing : {}
  listener_arn = each.value.listener_rule.listener_arn

  # ALB: explicit priority prevents DuplicatePriority collision on shared listeners
  # NLB: null — priority not applicable, AWS auto-assigns
  priority = each.value.type == "alb" ? (
    each.value.listener_rule.priority != null
      ? each.value.listener_rule.priority
      : random_integer.priority[each.key].result
  ) : null

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg[each.key].arn
  }

  # host_header condition — ALB only
  # NLB does not support routing conditions — all TCP traffic forwards unconditionally
  dynamic "condition" {
    for_each = each.value.type == "alb" && contains(["host_header", "mixed_route"], each.value.listener_rule.routing_method) ? [1] : []
    content {
      host_header {
        values = each.value.listener_rule.host_header_value
      }
    }
  }

  # path_pattern condition — ALB only
  dynamic "condition" {
    for_each = each.value.type == "alb" && contains(["path_pattern", "mixed_route"], each.value.listener_rule.routing_method) ? [1] : []
    content {
      path_pattern {
        values = [each.value.listener_rule.path_pattern_value]
      }
    }
  }

  tags = { Name = "${var.environment}-${var.ecs_cluster_prefix}-${each.key}-rule" }
}

## ============================================================
## Route53 DNS A Alias Records (only for LBs with dns.enabled)
## ============================================================
resource "aws_route53_record" "a_alias" {
  for_each = var.enable_module ? local.lb_with_dns : {}
  zone_id  = each.value.dns.hosted_zone_id
  name     = length(each.value.listener_rule.host_header_value) > 0 ? each.value.listener_rule.host_header_value[0] : each.key
  type     = "A"

  alias {
    name                   = "dualstack.${each.value.dns.lb_dns_name}"
    zone_id                = each.value.dns.lb_zone_id
    evaluate_target_health = true
  }
}
