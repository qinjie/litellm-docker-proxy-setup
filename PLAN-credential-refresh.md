# Plan: fast pickup of refreshed AWS credentials

**Status:** proposed
**Date:** 2026-09-22
**Scope:** make the running proxy observe a rewritten `~/.env.aws` within one
request, instead of up to 300s later plus a process restart.

## Out of scope

Refreshing the credentials themselves. A host-side script already owns that and
writes `~/.env.aws`; this plan does not replace, schedule, or wrap it. No
`launchd` agent is added.

## Findings in the current design

Credentials reach litellm as process environment variables sourced at startup
(`entrypoint.sh:11-18`). A process environment cannot be mutated from outside,
so every refresh requires a **restart** of litellm. `entrypoint.sh` therefore
carries a FIFO log monitor, a flag file, a cooldown, and a checksum poller to
decide when to restart. Five defects follow from that:

1. **The env-file poll clock is keyed to the wrong event.** `entrypoint.sh:117`
   compares `RELOAD_INTERVAL` (300s) against `CURRENT_TIME - LAST_RELOAD_TIME` —
   time since the last *reload*, not since the last *check*. Fresh credentials
   can sit unread for up to 300s, and every reload restarts that blackout.

2. **The reactive path cannot fire for the error Bedrock actually raises.**
   `entrypoint.sh:32` matches only `security token ... is expired`. boto3 raises
   **`ExpiredTokenException`**, which no pattern matches.

3. **Errors may never reach the monitored stream.** The monitor reads litellm's
   stdout, but `litellm_config.yaml:47-50` enables `json_logs` with
   `log_file_path: /app/logs/litellm.log`, so error text can bypass stdout.

4. **The cooldown discards the signal.** `entrypoint.sh:65-69` — inside the 30s
   cooldown the reload is skipped *and* `RELOAD_FLAG` is deleted. The monitor
   re-arms only on the next matching line (`entrypoint.sh:33`), so a further
   request must fail.

5. **Restart is destructive.** `stop_litellm` kills the process, dropping
   in-flight requests, and litellm cold-start costs seconds. `sleep 5`
   (`entrypoint.sh:97`) adds up to 5s before the restart even begins.

Taken together: defects 2 and 3 mean the reactive path likely never fires, so
recovery in practice depends on defect 1's 300s poll.

## Design

Stop feeding credentials through the environment. Use botocore's
`credential_process`, which is re-invoked *while the process runs*.

- **Shim** (`scripts/aws-creds-shim.sh`, mounted into the container) reads the
  mounted `~/.env.aws` and emits `credential_process` v1 JSON.
- **AWS config** (`scripts/aws-config`, mounted) defines one profile whose
  `credential_process` is that shim. `AWS_CONFIG_FILE` points at it, so this
  works regardless of which user the image runs as.
- **`litellm_config.yaml`** sets `aws_profile_name` on each Bedrock model.
- **`entrypoint.sh`** collapses to `exec litellm ...`; the FIFO, flag file,
  cooldown, and checksum loop are deleted.

### Why pickup becomes per-request

litellm's `base_aws_llm.py` special-cases `aws_profile_name`: it calls
`_auth_with_aws_profile` directly, **bypassing `_get_or_set_cached_credentials`,
so a fresh `boto3.Session` is built per invocation and the profile is re-resolved
from disk each time**. The shim therefore runs per request, and a rewritten
`~/.env.aws` is in effect on the next request.

This must be confirmed against the running container, not assumed from source —
see Verification V2.

### The missing `Expiration` field

`~/.env.aws` contains only `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
`AWS_SESSION_TOKEN`, `AWS_DEFAULT_REGION`. botocore's `ProcessProvider` treats a
payload **without** `Expiration` as static, non-refreshable credentials.

Since per-request re-invocation (above) is what delivers freshness, `Expiration`
is not load-bearing here. The shim will:

- pass through `AWS_CREDENTIAL_EXPIRATION` when present, and
- otherwise synthesize a short expiry, so botocore treats the credentials as
  refreshable rather than pinning them for the life of a session.

Optional, owned by the host script and not required by this plan: emit
`AWS_CREDENTIAL_EXPIRATION` (the `Expiration` that `isengardcli` already
returns) into `~/.env.aws`. That lets botocore refresh ahead of real expiry
rather than relying on per-request re-resolution.

## Risk: bind-mounted file and inode replacement

`docker-compose.yml:17` bind-mounts a single **file** (`~/.env.aws`). Docker
resolves that to an inode at container start. If the host refresh script writes
to a temp file and `mv`s it into place, the inode changes and **the container
keeps reading the old file indefinitely** — no amount of shim polling helps.

If the script instead truncates and rewrites in place, the container sees
updates. This determines whether the mount can stay as-is:

- **in-place rewrite** → keep the file mount.
- **atomic replace via `mv`** → mount a dedicated *directory* instead and read
  the file from inside it, so inode replacement is visible.

Must be established empirically (Verification V1) before the mount is finalized.
A partially written file is also possible under in-place rewrite, so the shim
must fail cleanly on a malformed read rather than emit truncated JSON.

## Tasks

1. `scripts/aws-creds-shim.sh` — read mounted env file, emit v1 JSON; exit
   non-zero with a stderr message if any of the three credential fields is
   missing or the file is unreadable. Never echo secret values to stderr or logs.
2. `scripts/aws-config` — single profile with `credential_process`.
3. `docker-compose.yml` — mount shim and config, set `AWS_CONFIG_FILE`, settle
   the mount shape per V1, and stop supplying AWS credentials via `env_file`.
4. `litellm_config.yaml` — add `aws_profile_name` to the six Bedrock entries.
5. `entrypoint.sh` — reduce to `exec litellm`.
6. `README.md` — document the mechanism and the optional
   `AWS_CREDENTIAL_EXPIRATION` line.

## Verification

Runtime evidence required; source inspection is not sufficient.

- **V1 — inode behaviour.** Identify how the host script writes `~/.env.aws`
  (in-place vs `mv`). With the container up, rewrite the file and `docker exec`
  a read to confirm the container observes new content. Settles task 3.
- **V2 — per-request invocation.** Have the shim append a timestamp to a
  counter file, issue N requests, assert the count advances — proving the shim
  is re-invoked per request rather than cached for the process lifetime.
- **V3 — no-restart pickup.** Record litellm's PID, rewrite `~/.env.aws` with
  valid fresh credentials, issue a request, confirm it succeeds **and** the PID
  is unchanged.
- **V4 — expired-credential recovery.** Point the file at expired credentials,
  observe the request fail, rewrite with valid ones, confirm the next request
  succeeds with no restart and no manual intervention.
- **V5 — malformed input.** Truncate the file mid-write; confirm the shim exits
  non-zero with a clear message and leaks no secret material.
- **V6 — baseline.** `curl -f http://localhost:8000/health` passes and a
  completion against `claude-sonnet-4-5` succeeds.

## Open question

Blocks V1 and task 3: the path of the existing host refresh script, so its write
strategy can be read rather than guessed.
