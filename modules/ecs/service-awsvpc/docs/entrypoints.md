# Command & Entrypoint — Reference Guide

Covers `configure_command` and `configure_entrypoint` in the `ecs_task_definition.container_definitions` block.

> For the concept overview and Docker interaction table, see **README.md → Section 2: Container: Command & Entrypoint**.
> This document covers: variable reference, usage patterns, troubleshooting.

---

## Table of Contents

- [Variable Reference](#variable-reference)
- [Docker Override Interaction](#docker-override-interaction)
- [Usage Patterns](#usage-patterns)
- [Common Mistakes](#common-mistakes)
- [Troubleshooting](#troubleshooting)

---

## Variable Reference

Both fields live inside `ecs_task_definition.container_definitions`. Both are optional — disabled by default.

```hcl
ecs_task_definition = {
  task_name = "my-service"
  container_definitions = {
    container_image = "..."
    container_port  = 8000
    fargate_cpu     = 512
    fargate_memory  = 1024

    configure_command = {
      enabled = true                       # false = Docker image CMD used as-is
      command = ["node", "dist/server.js"] # list of strings — NOT a single shell string
    }

    configure_entrypoint = {
      enabled    = true
      entrypoint = ["/bin/sh", "-c"]       # replaces Docker image ENTRYPOINT
    }
  }
}
```

| Field | Type | Default | Purpose |
|---|---|---|---|
| `configure_command.enabled` | `bool` | `false` | Toggle — when false, command block is omitted from task definition |
| `configure_command.command` | `list(string)` | `[]` | Overrides Docker `CMD` |
| `configure_entrypoint.enabled` | `bool` | `false` | Toggle |
| `configure_entrypoint.entrypoint` | `list(string)` | `[]` | Overrides Docker `ENTRYPOINT` |

---

## Docker Override Interaction

AWS ECS maps `configure_command` → container `command` and `configure_entrypoint` → container `entryPoint`, which override the Docker image's `CMD` and `ENTRYPOINT` respectively.

```
Dockerfile             configure_entrypoint    configure_command     Runs
─────────────────────────────────────────────────────────────────────────
ENTRYPOINT ["node"]    not set                 not set               node (no args → likely crashes)
CMD ["app.js"]

ENTRYPOINT ["node"]    not set                 ["worker.js"]         node worker.js
CMD ["app.js"]

ENTRYPOINT ["node"]    ["/bin/sh", "-c"]       ["./start.sh"]        /bin/sh -c ./start.sh
CMD ["app.js"]

(no ENTRYPOINT)        not set                 ["python","main.py"]  python main.py
CMD ["python","app.py"]
```

**Rule of thumb:**
- Change what runs → use `configure_command`
- Change the shell or wrapper → use `configure_entrypoint`
- Avoid both together unless you know Docker's exec-form behaviour

---

## Usage Patterns

### Pattern 1 — Same image, multiple roles

One Docker image deployed as API, worker, and scheduler. Only `configure_command` differs.

```hcl
# API server
configure_command = {
  enabled = true
  command = ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
}

# Queue worker (same image)
configure_command = {
  enabled = true
  command = ["celery", "-A", "app.worker", "worker", "--loglevel=info", "--concurrency=4"]
}

# Beat scheduler (same image)
configure_command = {
  enabled = true
  command = ["celery", "-A", "app.worker", "beat", "--loglevel=info"]
}
```

---

### Pattern 2 — Environment-conditional command

Different startup mode per environment without separate Docker images.

```hcl
configure_command = {
  enabled = true
  command = var.environment == "production" ? ["start", "--optimized"] : ["start-dev"]
}
```

---

### Pattern 3 — Database migration before main process

Run migration then hand off to main process in a single container start.

```hcl
configure_entrypoint = {
  enabled    = true
  entrypoint = ["/bin/sh", "-c"]
}

configure_command = {
  enabled = true
  command = ["python manage.py migrate && exec uvicorn app.main:app --host 0.0.0.0"]
}
```

> **Note:** `exec` in the command is important — it replaces the shell process so the app receives SIGTERM correctly on container stop.

---

### Pattern 4 — Custom startup script

```hcl
configure_entrypoint = {
  enabled    = true
  entrypoint = ["/docker-entrypoint.sh"]
}

# configure_command not needed if the script handles everything
```

---

### Pattern 5 — Debug: override to shell (non-production only)

```hcl
configure_entrypoint = {
  enabled    = true
  entrypoint = ["/bin/sh"]
}

configure_command = {
  enabled = true
  command = ["-c", "while true; do sleep 30; done"]  # keep container alive for exec
}
```

Then exec into the container:
```bash
aws ecs execute-command \
  --cluster <cluster-name> \
  --task <task-arn> \
  --container <container-name> \
  --command "/bin/sh" \
  --interactive
```

> **Requires `enable_exec_command = true`** in the module call. Without it, the ECS service rejects the exec request and the task role lacks `ssmmessages:*` permissions.

---

## Common Mistakes

### 1 — Command as a single string (fails)

```hcl
# WRONG — single string, not an array
configure_command = {
  enabled = true
  command = ["node dist/server.js"]  # ECS passes this as one arg → "no such file: node dist/server.js"
}

# CORRECT — each token is a separate list element
configure_command = {
  enabled = true
  command = ["node", "dist/server.js"]
}
```

### 2 — Shell features without a shell wrapper

```hcl
# WRONG — pipes and && only work inside a shell
configure_command = {
  enabled = true
  command = ["python", "migrate.py", "&&", "uvicorn", "app:main"]  # && is passed as literal arg
}

# CORRECT — wrap in sh -c
configure_entrypoint = { enabled = true, entrypoint = ["/bin/sh", "-c"] }
configure_command    = { enabled = true, command = ["python migrate.py && exec uvicorn app:main"] }
```

### 3 — `enabled = false` but command list set (ignored silently)

```hcl
configure_command = {
  enabled = false         # ← this means the command block is NOT sent to ECS
  command = ["worker.py"] # ← ignored — Docker image CMD runs instead
}
```

If command doesn't take effect, check `enabled = true` first.

### 4 — `health_check_grace_period_seconds` too short

When overriding command with a slow-starting service, ECS deregisters the task from the ALB before it's ready if `health_check_grace_period_seconds` is less than actual startup time.

```hcl
configure_ecs_service = {
  health_check_grace_period_seconds = 120  # must be >= configure_healthcheck.startPeriod
}
```

---

## Troubleshooting

### Container exits immediately after start

**Diagnosis:**
```bash
aws ecs describe-tasks --cluster <cluster> --tasks <task-arn> \
  --query 'tasks[0].stoppedReason'

aws logs tail /ecs/<env>-<prefix>-<task-name> --since 15m
```

**Common causes:**

| Symptom in logs | Likely cause | Fix |
|---|---|---|
| `exec: "node dist/server.js": no such file` | Command passed as single string | Split into list |
| `command not found` | Binary not in container PATH | Use full path `/usr/local/bin/node` |
| `No module named app.worker` | Wrong working directory or Python path | Add `WORKDIR` to Dockerfile or prepend `cd /app &&` |
| No logs at all | Container exits before log driver attaches | Increase `startPeriod`, check entrypoint script exits on error |

---

### Command override not taking effect

1. Verify `enabled = true` (most common mistake)
2. Run `terraform plan` — confirm task definition revision bumps
3. Check AWS Console → ECS → Task Definition → JSON → confirm `command` field present
4. Force new deployment after task definition update:
   ```bash
   aws ecs update-service --cluster <cluster> --service <service> --force-new-deployment
   ```

---

### Health check failing after command change

`startPeriod` in `configure_healthcheck` must cover the full startup time of the new command. Step-by-step check:

```bash
# 1. Check ECS health check status
aws ecs describe-tasks --cluster <cluster> --tasks <task-arn> \
  --query 'tasks[0].containers[0].healthStatus'

# 2. Tail container logs during startup
aws logs tail /ecs/<env>-<prefix>-<task-name> --since 10m --follow

# 3. If task is running but health check failing — exec in and test manually
aws ecs execute-command --cluster <cluster> --task <task-arn> \
  --container <container-name> --command "/bin/sh" --interactive
# then inside container:
# wget --quiet --tries=1 --spider http://localhost:8080/health/ready || echo FAIL
```

---

### SIGTERM not handled — task hangs on stop

Happens when `configure_entrypoint` runs a shell script that doesn't forward signals to the child process.

```bash
# BAD — shell script does not forward SIGTERM to app
#!/bin/sh
python app.py   # shell receives SIGTERM but app.py does not

# GOOD — exec replaces shell with app process directly
#!/bin/sh
exec python app.py   # app.py receives SIGTERM from ECS
```

ECS sends SIGTERM on task stop and waits `stopTimeout` seconds (default 30s) before SIGKILL. If app doesn't handle SIGTERM, it gets force-killed — in-flight requests dropped.
