# Monitoring long-running Docker builds (notes for agents)

This repo ended up needing multi-hour `docker build` runs (Spack compiles, fallback-to-source, etc.). A bunch of subtle failure modes showed up.

## 1) Don’t rely on `pgrep docker build` alone

When a build is launched via a wrapper like:

```bash
DOCKER_BUILDKIT=1 docker build ... | tee -a dp3-build.log
```

there are multiple processes:
- the *supervisor shell* (your wrapper)
- `docker build ...`
- buildkit workers / `runc` executors

Depending on how the build is started (backgrounded, tool timeouts, HUP), the visible `docker build` process may disappear or be hard to match, while buildkit workers still exist.

**Lesson:** Prefer a single source of truth you control (PID file + status file) over ad-hoc process matching.

## 2) Always use a PID file + status file for long builds

Create a build supervisor script that:
- writes `dp3-build.pid` = `$$` (supervisor PID)
- writes `dp3-build.status` = `running|success|failed:<rc>|stale:<oldpid>`
- traps `EXIT INT TERM HUP` to update status and remove pidfile
- detects and clears stale pidfiles on startup

This makes watchdogs trivial:

```bash
pid=$(cat dp3-build.pid 2>/dev/null || true)
status=$(cat dp3-build.status 2>/dev/null || true)
if [ -n "$pid" ] && ps -p "$pid" >/dev/null 2>&1; then
  echo RUNNING
else
  echo STOPPED status=$status
fi
```

## 3) Avoid pipes/tee for detached builds

Pipes are fragile under backgrounding: the parent process can exit, causing SIGPIPE/HUP and truncation/partial logs.

Instead:
- redirect stdout/stderr directly to a file via `exec >>log 2>&1`
- launch with `nohup setsid ./build.sh </dev/null >/dev/null 2>&1 &`

This avoids the “log is empty/0 bytes” or “build silently died when tool call ended” issues.

## 4) Separate “monitoring” from “messaging”

A cron job that only emits a `systemEvent` won’t automatically post to Discord.

If you need periodic Discord updates:
- either run a cron `agentTurn` (isolated) that uses OpenClaw `message.send`
- or have the build script post completion and watchdog post status

Also: keep watchdogs conservative. Auto-editing config from a cron can fight with the operator.

## 5) Detect build progress from the log

Even if processes are confusing, the log’s mtime and tail are strong indicators.

Suggested status payload:
- pidfile status + `ps -p $pid`
- log mtime
- last ~25 lines of `dp3-build.log`

## 6) Tooling timeouts can kill your supervisor

When builds are launched from an agent/tool call, the platform may SIGTERM/SIGKILL the command after some time.

**Mitigation:** Start detached (`nohup setsid`) and then only *poll* status/logs in later tool calls.

## 7) If you must cancel

Prefer killing the supervisor PID (from pidfile) and/or matching `docker build ... dp3.Dockerfile`.
Always clean stale pid/status files before restarting.

## 8) Prefer cache-preserving changes during long build cycles

When the build has already compiled a large dependency DAG, changing early Dockerfile layers can invalidate cache and force hours of rebuild.

Rules of thumb:
- avoid editing early layers unless the change is necessary
- if you did break something, fix it immediately (don’t leave the repo in a broken state)
- split installs into multiple layers when safe, so later failures don’t wipe earlier progress

---

These notes came from debugging a Spack-based DP3/EveryBeam container build that frequently fell back to source builds and ran for hours.
