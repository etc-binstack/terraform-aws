# Security Group — Configuration Guide

Documents the security group model for ECS Fargate tasks in this module, explains the three ingress categories, and covers the two input approaches for custom rules.

---

## Table of Contents

- [Security Group Model](#security-group-model)
- [Rules Always Created](#rules-always-created)
- [Variable Reference](#variable-reference)
- [Custom Ingress Rules — Input Approaches](#custom-ingress-rules--input-approaches)
- [Usage Examples](#usage-examples)
- [Why map(object) Over list(object)](#why-mapobject-over-listobject)

---

## Security Group Model

Each ECS service deployed by this module gets **one dedicated security group**. It is never shared between services.

```
Internet / ALB
      │
 [ALB Security Group]   ← managed by the ALB module (caller-owned)
      │
 [ECS Task Security Group]   ← created by THIS module
      │
 [RDS / Redis / Internal SG]  ← caller adds this SG as ingress source
```

The ECS task security group controls what can reach the container port. The module creates it from `network_configuration` — no manual security group resource needed per service.

---

## Rules Always Created

The module creates these rules unconditionally when `enable_module = true`:

| Rule ID | Direction | Port | Source | Created By |
|---|---|---|---|---|
| `e01` | Egress | all | `0.0.0.0/0` | Always — containers need outbound for ECR, Secrets Manager, Kinesis |
| `i01` | Ingress | `container_port` | `vpc_cidr` | Always — allows intra-VPC traffic (ALB, other ECS tasks) |
| `i02` | Ingress | `container_port` | `peering_cidrs[]` | Only when `vpcpeer_ingress_rule.peering_cidrs` is non-empty |
| `ci03` | Ingress | custom | custom | Only when `custom_ingress_rule.create_rules` map is non-empty |

**`i01` source is `vpc_cidr`, not the ALB security group.** This means any resource inside the VPC can reach the container port. Tighten this in high-security environments by removing `i01` and adding a custom rule scoped to the ALB security group ID instead.

---

## Variable Reference

Security group rules are configured inside `network_configuration`:

```hcl
network_configuration = {
  vpc_id         = string        # required
  vpc_subnet_ids = list(string)  # required — private subnets
  vpc_cidr       = string        # required — used as source for rule i01

  aditional_security_group_rules = {

    # Rule i02 — one ingress rule for ALL peering CIDRs combined
    vpcpeer_ingress_rule = {
      peering_cidrs = list(string)  # e.g. ["10.50.0.0/16", "172.16.0.0/12"]
    }

    # Rule ci03 — one rule per map key (for_each, stable diffs)
    custom_ingress_rule = {
      create_rules = map(object({
        from_port   = number
        to_port     = number
        protocol    = string        # "tcp" | "udp" | "-1" (all)
        cidr_blocks = list(string)
        description = string
      }))
    }

  }
}
```

**`aditional_security_group_rules` is fully optional.** Omitting it means only `e01` and `i01` are created.

---

## Custom Ingress Rules — Input Approaches

Two approaches exist. The module implements **Option 2 (map)** — documented here for clarity.

### Option 1 — `list(object)` with `count` (not used in this module)

```hcl
variable "custom_ingress_rules" {
  type = list(object({
    from_port   = number
    to_port     = number
    protocol    = string
    cidr_blocks = list(string)
    description = string
  }))
  default = []
}

resource "aws_security_group_rule" "custom_ingress" {
  count             = length(var.custom_ingress_rules)
  type              = "ingress"
  from_port         = var.custom_ingress_rules[count.index].from_port
  to_port           = var.custom_ingress_rules[count.index].to_port
  protocol          = var.custom_ingress_rules[count.index].protocol
  cidr_blocks       = var.custom_ingress_rules[count.index].cidr_blocks
  description       = var.custom_ingress_rules[count.index].description
  security_group_id = aws_security_group.sgp[0].id
}
```

**Problem:** Removing any element from the middle of the list shifts all subsequent indices. Terraform plans a destroy + recreate of every rule after the removed one — unnecessary churn on stable rules.

---

### Option 2 — `map(object)` with `for_each` ✅ (used in this module)

```hcl
variable "custom_ingress_map" {
  type = map(object({
    from_port   = number
    to_port     = number
    protocol    = string
    cidr_blocks = list(string)
    description = string
  }))
  default = {}
}

resource "aws_security_group_rule" "ci03" {
  for_each          = var.enable_module ? try(local.custom_rules.create_rules, {}) : {}
  type              = "ingress"
  from_port         = each.value.from_port
  to_port           = each.value.to_port
  protocol          = each.value.protocol
  cidr_blocks       = each.value.cidr_blocks
  description       = each.value.description
  security_group_id = aws_security_group.sgp[0].id
}
```

**Each map key is a stable identity.** Removing `allow_prometheus` only destroys that one rule — no other rules are touched.

---

## Why map(object) Over list(object)

```
Scenario: 3 rules exist. Remove rule at index 0 (list) vs key "allow_a" (map).

list(object) — count:                    map(object) — for_each:
  rule[0] allow_a  ─── DESTROY             allow_a  ─── DESTROY
  rule[1] allow_b  ─── DESTROY+CREATE      allow_b  ─── no change
  rule[2] allow_c  ─── DESTROY+CREATE      allow_c  ─── no change

Plan: 5 operations                       Plan: 1 operation
```

Map keys are also self-documenting — `allow_prometheus` conveys intent; `rule[2]` does not.

---

## Usage Examples

### Example 1 — No additional rules

Only `e01` (egress all) and `i01` (VPC CIDR ingress) are created.

```hcl
network_configuration = {
  vpc_id         = module.vpc.vpc_id
  vpc_subnet_ids = module.vpc.private_subnet_ids
  vpc_cidr       = module.vpc.vpc_cidr
}
```

---

### Example 2 — VPC peering only

Allows traffic from two peered VPCs on `container_port`.

```hcl
network_configuration = {
  vpc_id         = module.vpc.vpc_id
  vpc_subnet_ids = module.vpc.private_subnet_ids
  vpc_cidr       = module.vpc.vpc_cidr

  aditional_security_group_rules = {
    vpcpeer_ingress_rule = {
      peering_cidrs = [
        "10.50.0.0/16",   # shared-services VPC
        "172.16.0.0/12"   # on-premises via Direct Connect
      ]
    }
  }
}
```

---

### Example 3 — Custom rules only

Exposes Prometheus metrics port and gRPC port to specific subnets.

```hcl
network_configuration = {
  vpc_id         = module.vpc.vpc_id
  vpc_subnet_ids = module.vpc.private_subnet_ids
  vpc_cidr       = module.vpc.vpc_cidr

  aditional_security_group_rules = {
    custom_ingress_rule = {
      create_rules = {
        allow_prometheus = {
          from_port   = 9090
          to_port     = 9090
          protocol    = "tcp"
          cidr_blocks = ["10.40.100.0/24"]  # monitoring subnet
          description = "Prometheus scrape from monitoring subnet"
        }
        allow_grpc = {
          from_port   = 50051
          to_port     = 50051
          protocol    = "tcp"
          cidr_blocks = ["10.40.0.0/16"]
          description = "gRPC from internal services"
        }
      }
    }
  }
}
```

---

### Example 4 — Peering + custom rules combined

```hcl
network_configuration = {
  vpc_id         = module.vpc.vpc_id
  vpc_subnet_ids = module.vpc.private_subnet_ids
  vpc_cidr       = module.vpc.vpc_cidr

  aditional_security_group_rules = {
    vpcpeer_ingress_rule = {
      peering_cidrs = ["10.50.0.0/16"]
    }
    custom_ingress_rule = {
      create_rules = {
        allow_prometheus = {
          from_port   = 9090
          to_port     = 9090
          protocol    = "tcp"
          cidr_blocks = ["10.40.100.0/24"]
          description = "Prometheus scrape from monitoring subnet"
        }
        allow_admin_api = {
          from_port   = 8443
          to_port     = 8443
          protocol    = "tcp"
          cidr_blocks = ["10.40.200.0/24"]
          description = "Admin API access from bastion subnet"
        }
      }
    }
  }
}
```

---

### Example 5 — Multiple load balancers (ALB + NLB) with security group

When using `configure_load_balancers` with multiple entries (ALB on 8080 + NLB on 9090), add custom rules for each port that the ALB/NLB does not cover via `vpc_cidr`:

```hcl
# configure_load_balancers defines what LBs attach to the service
configure_load_balancers = [
  {
    name           = "public-alb"
    type           = "alb"
    container_port = 8080
    ...
  },
  {
    name           = "internal-nlb"
    type           = "nlb"
    container_port = 9090
    ...
  }
]

# Rule i01 only covers host_port (first container_port by default).
# Add explicit rules for additional ports used by the second LB:
network_configuration = {
  vpc_id         = module.vpc.vpc_id
  vpc_subnet_ids = module.vpc.private_subnet_ids
  vpc_cidr       = module.vpc.vpc_cidr

  aditional_security_group_rules = {
    custom_ingress_rule = {
      create_rules = {
        allow_nlb_port = {
          from_port   = 9090
          to_port     = 9090
          protocol    = "tcp"
          cidr_blocks = [module.vpc.vpc_cidr]
          description = "NLB internal port from VPC"
        }
      }
    }
  }
}
```

> **Note on multi-port services:** Rule `i01` uses `local.host_port` (the first container port). When `configure_load_balancers` has entries on different ports, add custom rules for the secondary ports as shown above.

---

## Security Group Resource Summary

| Resource | Type | Created When |
|---|---|---|
| `aws_security_group.sgp` | SG shell | `enable_module = true` |
| `aws_security_group_rule.e01` | Egress all | Always |
| `aws_security_group_rule.i01` | Ingress VPC CIDR → `host_port` | Always |
| `aws_security_group_rule.i02` | Ingress peering CIDRs → `host_port` | `vpcpeer_ingress_rule.peering_cidrs` non-empty |
| `aws_security_group_rule.ci03` | Ingress custom (one per map key) | `custom_ingress_rule.create_rules` non-empty |
