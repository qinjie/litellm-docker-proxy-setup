# Plan: fast pickup of refreshed AWS credentials

**Status:** proposed
**Date:** 2026-09-22
**Scope:** make the running proxy observe a rewritten `~/.env.aws` promptly and
**without a process restart**, instead of up to 300s later plus a restart. The
guaranteed bound is set by the `Expiration` refresh schedule (Mechanism A); the
common case is faster (Mechanism B), but that is not promised.

## Out of scope

Refreshing the credentials themselves. A host-side script already owns that and
writes `~/.env.aws`; this plan does not replace, schedule, or wrap it. No
`launchd` agent is added.

## Operating model

Refresh is **human-driven and unscheduled** — the host script requires a person,
so it cannot be run on a timer. Two consequences shape the design:

- Credentials in `~/.env.aws` may be **expired for an unbounded period**, from
  the moment they lapse until a person happens to refresh them. Requests during
  that window cannot be rescued; no valid credentials exist.
- The property that matters is therefore: **the first request issued after the
  file is rewritten must succeed, with no restart and no operator action beyond
  the refresh itself.** Latency is measured from the file changing, not from
  expiry.

The proxy must also not degrade during the expired window: it should keep
failing cleanly per request and remain ready, rather than restart-looping or
wedging itself.

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

### Two independent reasons pickup is fast

**Mechanism A — botocore refresh (load-bearing).** `ProcessProvider` returns
`RefreshableCredentials` when the payload carries `Expiration`, and re-invokes
the shim once the remaining lifetime falls inside botocore's advisory refresh
window (15 minutes). The shim will therefore always emit an `Expiration` set a
short interval ahead — inside that window — so refresh is attempted on
effectively every credential fetch, *within a single long-lived session*. This
holds no matter how litellm caches.

**Mechanism B — litellm re-resolving per call (observed, not contracted).**
On `main`, `base_aws_llm.py:482-484` dispatches the `aws_profile_name` branch to
`_auth_with_aws_profile` and returns directly, **not** through
`_get_or_set_cached_credentials` as the other four auth branches do; and
`base_aws_llm.py:1393-1402` builds a fresh `boto3.Session(profile_name=...)` per
call. So the profile is re-resolved from disk each request.

Mechanism B is the faster of the two, but it is **internal behaviour, not a
documented contract**, and `docker-compose.yml:3` pins `main-latest` — a moving
tag. A future image could reintroduce caching on this path and silently
regress it. The design must remain correct on Mechanism A alone; B is an
optimisation, and the plan does not promise next-request pickup on its basis.

### `Expiration` must be emitted, and must be capped short

`~/.env.aws` contains only `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
`AWS_SESSION_TOKEN`, `AWS_DEFAULT_REGION`. botocore's `ProcessProvider` treats a
payload **without** `Expiration` as static, non-refreshable credentials — which
disables Mechanism A entirely and leaves freshness resting on the un-contracted
Mechanism B. So the shim must always emit one.

**It must also always cap it.** The emitted value governs *when botocore next
re-reads the file*, and is not a safety property — emitting an expiry earlier
than the credential's true expiry only makes botocore re-read more often, which
is precisely what is wanted. Emitting the real expiry is actively harmful here:
these credentials carry a ~12h lifetime, far outside botocore's 15-minute
advisory window, so botocore would not re-invoke the shim for roughly 11h45m. A
file rewritten by hand inside that window would be missed for hours — defeating
the entire purpose. Given the operating model above, a hand-edit landing in that
window is the *expected* case, not an edge case.

The shim therefore emits:

```
Expiration = min(AWS_CREDENTIAL_EXPIRATION if present, now + CAP)
```

with `CAP` short enough to sit inside the advisory window. The `min()` matters in
both directions: the cap bounds how long a rewritten file can go unnoticed, and
honouring a nearer real expiry avoids advertising validity the credentials do not
have.

Tradeoff to settle in implementation: botocore also has a 10-minute *mandatory*
window, inside which a failed refresh raises instead of serving existing
credentials. A `CAP` short enough to force frequent re-reads sits in or near that
window, so a transient unreadable file surfaces as a failed request rather than
silent staleness — the preferable failure mode here. The chosen `CAP` must be
recorded with its reasoning, and V2b measures the bound it actually delivers.

Optional, and purely diagnostic given the cap: the host script may emit
`AWS_CREDENTIAL_EXPIRATION` (the `Expiration` that `isengardcli` already
returns). It lets the shim log genuine time-to-expiry, but it does **not**
improve pickup latency and must never widen the cap.

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

1. `scripts/aws-creds-shim.sh` — read mounted env file, emit v1 JSON with
   `Expiration = min(AWS_CREDENTIAL_EXPIRATION if present, now + CAP)`; exit
   non-zero with a stderr message if any of the three credential fields is
   missing or the file is unreadable. Never echo secret values to stderr or logs.
2. `scripts/aws-config` — single profile with `credential_process`.
3. `docker-compose.yml` — mount shim and config, set `AWS_CONFIG_FILE`, settle
   the mount shape per V1, and stop supplying AWS credentials via `env_file`.
4. `litellm_config.yaml` — add `aws_profile_name` to the six Bedrock entries.
5. `entrypoint.sh` — reduce to `exec litellm`.
6. `README.md` — document the mechanism, quote the V2b guaranteed staleness
   bound rather than the faster V2 combined figure, and describe the
   `AWS_CREDENTIAL_EXPIRATION` line the host script should emit.

## Verification

Runtime evidence required; source inspection is not sufficient.

- **V1 — inode behaviour.** Identify how the host script writes `~/.env.aws`
  (in-place vs `mv`). With the container up, rewrite the file and `docker exec`
  a read to confirm the container observes new content. Settles task 3.
- **V2 — shim re-invocation, and which mechanism supplies it.** Have the shim
  append a timestamp to a counter file, then issue N requests and record how
  many invocations result. This measures the *combined* effect of Mechanisms A
  and B; it does not by itself distinguish them. Record the observed ratio and
  the image digest it was measured against, since Mechanism B is not contracted.
- **V2b — staleness bound without Mechanism B.** Establish the worst case if
  litellm reintroduces caching on the profile path: hold one session open and
  confirm the shim is still re-invoked on the `Expiration`-driven schedule
  alone. This is the number the design actually guarantees, and it is what the
  README should quote — not V2's faster combined figure.
- **V3 — no-restart pickup.** Record litellm's PID, rewrite `~/.env.aws` with
  valid fresh credentials, issue a request, confirm it succeeds **and** the PID
  is unchanged.
- **V4 — recovery after a prolonged expired window.** The primary scenario, per
  the operating model. Point the file at expired credentials, leave it expired
  across several request attempts, confirm each fails cleanly and the proxy stays
  up and does not restart-loop; then rewrite with valid credentials and confirm
  the **next** request succeeds with no restart and no operator action.
- **V4b — the cap is not widened by a real expiry.** Regression guard for the
  defect this plan corrects. Supply `AWS_CREDENTIAL_EXPIRATION` ~12h in the
  future, then confirm the shim still emits a capped `Expiration` and that a file
  rewritten minutes later is picked up within the V2b bound — not held for
  ~11h45m.
- **V5 — malformed input.** Truncate the file mid-write; confirm the shim exits
  non-zero with a clear message and leaks no secret material.
- **V6 — baseline.** `curl -f http://localhost:8000/health` passes and a
  completion against `claude-sonnet-4-5` succeeds.

## Open question

Blocks V1 and task 3: the path of the existing host refresh script, so its write
strategy can be read rather than guessed.
