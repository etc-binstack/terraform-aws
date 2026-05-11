# Git Commit & Release Guide

Follow this process every time. Deviating breaks callers pinned to version tags.

---

## Golden Rule

**Never force-push to `main`. Never delete published tags.**

Callers use `?ref=v1.0.0` in their `source`. If that tag disappears or main history is rewritten → their `terraform init` breaks silently with no warning.

---

## Branching Strategy

```
main                        ← stable, tagged releases only
  └── feature/xyz           ← all development work
  └── fix/xyz               ← bug fixes
  └── docs/xyz              ← documentation only
  └── release/v2.0.0        ← release stabilisation (optional)
```

Never commit directly to `main`. Always PR.

---

## Branch Naming

```bash
feature/ecs-service-multi-lb
fix/iam-region-hardcoded
docs/cluster-readme-update
refactor/vault-policy-scope
release/v2.0.0
```

---

## Commit Message Convention (Conventional Commits)

```
<type>(<scope>): <short description>

type:
  feat      new feature
  fix       bug fix
  docs      documentation only
  refactor  code change, no behaviour change
  chore     build, deps, tooling
  release   version bump

scope (optional):
  ecs/service-awsvpc
  ecs/cluster
  monitoring/cw-alarm-notifier

Examples:
  feat(ecs/service-awsvpc): add multiple load balancer support
  fix(monitoring/cw-alarm-notifier): use cross_vault.region not hardcoded us-east-2
  docs(ecs/cluster): add network mode compatibility section
  chore: add versions.tf to all modules
```

---

## Versioning — Semantic Versioning (SemVer)

```
v{MAJOR}.{MINOR}.{PATCH}

MAJOR  Breaking change — callers MUST update their source reference
       Examples: variable renamed, output removed, resource destroyed+recreated

MINOR  New feature — backward compatible, callers unchanged
       Examples: new optional variable added, new output, new resource count=0 default

PATCH  Bug fix — backward compatible, no resource changes
       Examples: wrong region default, IAM scope fix, description typo
```

**Rule:** Adding optional variables (with defaults) = always MINOR, never MAJOR.

---

## Release Checklist — Before Every Tag

```
[ ] All changes merged to main via reviewed PR
[ ] No hardcoded account IDs, regions, or company names in any .tf or .py file
[ ] versions.tf present in every changed module
[ ] README.md updated for changed modules (variables, outputs, examples)
[ ] examples/ updated if variable schema changed
[ ] terraform validate passes
[ ] No *.tfvars committed
[ ] No .terraform/ directories committed
[ ] No generated *.zip files committed (except pre-built Lambda packages)
```

---

## Tagging — Step by Step

### Step 1 — Confirm on main and clean

```bash
git checkout main
git pull origin main
git log --oneline -5     # PR merge commit should be latest
git status               # must show nothing to commit
```

### Step 2 — Create annotated tag

```bash
# Annotated tags appear in GitHub Releases and git log
git tag -a v1.0.0 -m "Initial release — ECS service, cluster, cw-alarm-notifier modules"
```

### Step 3 — Push tag

```bash
git push origin v1.0.0
```

### Step 4 — Create GitHub Release

GitHub → Releases → Draft new release → select tag `v1.0.0`

Include in release notes:
- Modules added or changed
- New variables introduced
- Breaking changes (MAJOR only)
- Migration steps (MAJOR only)

---

## Callers — How They Reference Modules

```hcl
# Pinned to exact version — safe, never changes
source = "github.com/etc-binstack/terraform-aws//modules/ecs/service-awsvpc?ref=v1.0.0"

# Pinned to tag — caller controls when they upgrade
source = "github.com/etc-binstack/terraform-aws//modules/ecs/cluster?ref=v1.2.0"
```

Callers who stay on `v1.0.0` are **completely unaffected** by v1.1.0, v1.2.0, or v2.0.0 releases. They choose when to upgrade.

---

## Patch Fix (no disruption to existing callers)

```bash
git checkout main && git pull
git checkout -b fix/iam-region-hardcoded

# make fix, commit
git commit -m "fix(monitoring/cw-alarm-notifier): use cross_vault.region not hardcoded us-east-2"

# PR → merge to main → then tag
git checkout main && git pull
git tag -a v1.0.1 -m "fix: cw-alarm-notifier cross-vault region hardcode removed"
git push origin v1.0.1
```

Callers on `?ref=v1.0.0` — unaffected. They get the fix only when they explicitly change to `?ref=v1.0.1`.

---

## Breaking Change (MAJOR bump)

When a variable is renamed, output is removed, or a resource is destroyed and recreated:

```bash
# 1. Document breaking change in PR description
# 2. Add migration steps to README or docs/MIGRATION.md
# 3. Bump MAJOR

git tag -a v2.0.0 -m "BREAKING: configure_alb replaced by configure_load_balancers list"
git push origin v2.0.0
```

Never silently change an existing tag. Always create a new tag.

### What callers do on MAJOR bump

```hcl
# Caller BEFORE — stays on v1 indefinitely, zero disruption
source = "...?ref=v1.0.0"

# Caller AFTER — opts in to v2 on their own schedule
source = "...?ref=v2.0.0"
# + updates their module call to new variable schema
```

---

## Hotfix on Old Major (rare)

Critical bug in v1.x AND callers cannot move to v2 yet:

```bash
# Branch from old tag
git checkout -b support/v1 v1.0.0

# Apply fix (cherry-pick from main or apply manually)
git cherry-pick <fix-commit-hash>

# Tag as patch on old major
git tag -a v1.0.2 -m "hotfix: critical IAM permission missing"
git push origin v1.0.2
git push origin support/v1
```

---

## Commands Reference

```bash
# List all tags
git tag -l

# List tags with messages
git tag -n

# Show what a tag points to
git show v1.0.0 --stat

# Tag a past commit (if you forgot to tag at merge time)
git log --oneline -10
git tag -a v1.0.0 <commit-hash> -m "message"
git push origin v1.0.0

# Delete local tag (only before pushing — if typo in tag name)
git tag -d v1.0.0

# Delete remote tag — EMERGENCY ONLY, only if zero callers use it
git push origin --delete v1.0.0
```

---

## .gitignore — Never Commit These

```
.terraform/        ← local Terraform cache
*.tfstate          ← state (contains real infrastructure ARNs + secrets)
*.tfvars           ← environment values (may contain passwords, API keys)
.env               ← environment secrets
*.pem / *.key      ← certificates and private keys
CLAUDE.md          ← AI context files
.claude/           ← AI session files
__pycache__/       ← Python cache
*.pyc              ← Python bytecode
```

Full list: `modules/monitoring/.gitignore`
