# Plan: fast pickup of refreshed AWS credentials

**Status:** implemented, not signed off. V4 is outstanding, blocked on VM memory, and
the expired-token case end to end waits for the first real expiry. See
[Outstanding](VERIFICATION-credential-refresh.md#outstanding).
**Date:** 2026-09-22
**Revised:** 2026-09-22 — re-reads are now delayed rather than per-request, at the
owner's direction. This reversed two earlier choices: `aws_profile_name` gave way
to `AWS_PROFILE`, and the short-capped `Expiration` gave way to one placed beyond
botocore's advisory window. Tasks 1 and 4 changed as a result.
**Revised again:** 2026-09-22 — two triggers instead of one, at the owner's
direction: a 15-minute schedule *and* a re-read on credential rejection. Adds the
failure-callback module (new task 4) and a `litellm_config.yaml` change that the
previous revision had ruled out. The "scheduled job" is implemented inside the
credential provider rather than as a timer, for reasons recorded under trigger 1.
**Scope:** make the running proxy observe a rewritten `~/.env.aws` **without a
process restart**, instead of up to 300s later plus a restart. Two re-read
triggers, per the owner's direction:

1. **Scheduled** — re-read on the first credential use once 15 minutes have passed
   since the last read. Request-driven, not a timer: an idle proxy reads nothing, and
   the first request after an idle gap re-reads.
2. **On error** — re-read when a request to the LLM fails with a credential
   rejection, rather than waiting out the schedule.

Neither is per-request. Trigger 2 has its own cooldown for exactly that reason; see
the two trigger sections under Design.

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
- The property that matters is therefore: **after the file is rewritten, the proxy
  uses the new credentials with no restart and no operator action beyond the refresh
  itself, within a bounded delay** — at most `REREAD_DELAY` (trigger 1), or one
  failed request after `ERROR_REREAD_COOLDOWN` (trigger 2), whichever comes first.
  The first request after the rewrite is **not** required to succeed. It may be
  served from credentials cached before the rewrite, and its failure is what arms
  trigger 2. This replaces an earlier "first request must succeed" criterion, which
  the owner's requirement of a delay before re-reading (2026-09-22) superseded.
  Latency is measured from the file changing, not from expiry.
- Re-reading the file on every request during that window is pure churn — nothing
  the container can do makes expired credentials work, and only a person can
  change that. So the file is re-read on a **delay**, not once per failed request:
  on the schedule at most once per `min(600, REREAD_DELAY)` (litellm's cache TTL
  and the shim's interval, whichever is shorter), plus at most one cache-drop
  attempt per `ERROR_REREAD_COOLDOWN` per worker process while AWS is rejecting
  requests. A successful drop makes the next request re-read.
- A credential rejection is nonetheless the **strongest available signal** that the
  file is worth re-reading, so it triggers one too — bounded by its own cooldown,
  which is what keeps "re-read on error" from collapsing back into "re-read per
  request" during a long expired window.

One precondition on the no-operator-action property, stated here because it
constrains the whole design: it holds when the file is rewritten **in place**. A
writer that *replaces* the file detaches the bind mount, and no container-side work
can recover from that — it takes either one manual restart or a different mount
shape. The host script rewrites in place (answered below), so the precondition holds.

The proxy must also not degrade during the expired window: it should keep
failing cleanly per request and remain ready, rather than restart-looping or
wedging itself.

Credential *acquisition* is entirely outside the container. Nothing here runs,
wraps, or depends on `isengardcli`.

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
- **`docker-compose.yml`** sets `AWS_PROFILE` and `AWS_CONFIG_FILE`, and stops
  supplying AWS credentials as environment variables. Both matter: botocore's
  environment provider outranks the profile, so a leftover `AWS_ACCESS_KEY_ID`
  in the container env silently wins and the shim is never consulted.
- **Failure callback** (`scripts/aws_credential_refresh.py`, mounted) invalidates the
  cached credentials when AWS rejects them, so the next request re-reads the file
  instead of waiting out the schedule. This is trigger 2.
- **`litellm_config.yaml`** gains exactly one thing: `litellm_settings.callbacks`
  registering that callback. No model entry changes — the absence of `aws_*`
  credential params is what selects the right code path.
- **`entrypoint.sh`** collapses to `exec litellm ...`; the FIFO, flag file,
  cooldown, and checksum loop are deleted.

### Why `AWS_PROFILE`, and not `aws_profile_name`

A delay between re-reads can only exist if the credentials object *survives*
between requests. That rules out the obvious wiring.

**Rejected — `aws_profile_name` per model.** `base_aws_llm.py:482-484` dispatches
that branch to `_auth_with_aws_profile` and returns directly, bypassing
`_get_or_set_cached_credentials`; `:1393-1402` then builds a fresh
`boto3.Session(profile_name=...)` per call. This is deliberate, and stated in the
source: *"Profiles and explicit session-token tuples are not cached here — shared
`Credentials` / refresh state must not span logical sessions"*
(`base_aws_llm.py:301-302`). Every request would therefore construct a new
provider and run the shim, re-reading the file per request. Correct, but the
opposite of the requirement.

**Chosen — ambient credentials via `AWS_PROFILE`.** With no `aws_*` credential
params set, `get_credentials` falls to its final branch,
`_get_or_set_cached_credentials(args, self._auth_with_env_vars)`
(`base_aws_llm.py:510`), and `_auth_with_env_vars` (`:1451-1460`) is just
`boto3.Session()` → `session.get_credentials()`. A plain session honours
`AWS_PROFILE` and `AWS_CONFIG_FILE`, so it resolves our profile and its
`credential_process` — and the resulting `RefreshableCredentials` object is
**cached** (ttl `None` → `InMemoryCache` `default_ttl`, 600s per
`base_aws_llm.py:291-293`). It therefore persists across requests, and botocore's
own refresh schedule decides when the shim runs again.

This is what makes `litellm_config.yaml` a no-op: the six Bedrock entries set only
`aws_region_name`, which selects no auth branch. Adding any credential param to a
model would divert it to a different branch and quietly reintroduce per-request
re-reads. That is a constraint to state in the README, not just here.

**Failure direction is safe.** litellm's caching is internal behaviour and
`docker-compose.yml:3` pins `main-latest`, a moving tag. But note which way a
regression cuts: if a future image stopped caching this branch, the shim would be
invoked more often, not less — the delay would degrade toward per-request reads
while pickup stays correct and gets *faster*. Nothing about correctness rests on
the cache. A longer TTL is equally harmless, because the cached object is
refreshable and botocore's schedule still governs re-reads.

### Trigger 1 — scheduled: `Expiration` is the re-read schedule

`~/.env.aws` contains only `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
`AWS_SESSION_TOKEN`, `AWS_DEFAULT_REGION` — inspected 2026-09-22, and there is **no
expiry field**. So the shim cannot derive an expiry; it must synthesise one.
Omitting it is not an option either: botocore's `ProcessProvider` treats a payload
without `Expiration` as static, non-refreshable credentials, which means it never
re-invokes the shim at all and the file is read exactly once per process.

The emitted value is therefore a **re-read schedule, not a validity claim.** AWS is
the sole authority on whether the credentials work; the only thing this timestamp
decides is when botocore next runs the shim.

Because botocore re-invokes the shim once remaining lifetime drops inside its
advisory refresh window, the interval between re-reads is set by placing
`Expiration` that far *beyond* the window:

```
Expiration = now + ADVISORY_WINDOW + REREAD_DELAY
```

`REREAD_DELAY` is then the re-read interval, and hence the worst-case lag between a
person rewriting the file and the proxy using it. Set to **900s** to meet the
15-minute requirement, overridable and bounded to `[1, 900]` — the upper bound *is*
the requirement, so a larger value would silently break it.

#### Why no cron job, and why the interval is really ~600s

The requirement says "scheduled job". This is a schedule, but not a separate timer,
for two reasons — one structural, one measured.

**Structural:** an external process cannot hand credentials to a running botocore
session. There is exactly one way into that session's credential state, and it is
this `credential_process` hook. A cron job inside the container could re-read the
file all day and the proxy would not see it. So the schedule has to live where the
credentials are resolved, which is here.

**Measured:** there are *two* caches in series, and the shorter one wins.
`_get_or_set_cached_credentials` stores the ambient-env credentials with `ttl=None`,
which `InMemoryCache.set_cache` resolves to `default_ttl` — **600s**
(`base_aws_llm.py:291-293`). When that entry lapses, the next request calls
`_auth_with_env_vars`, which builds a **fresh `boto3.Session`**
(`base_aws_llm.py:1451-1460`); a fresh session resolves credentials from scratch, so
it runs the shim. That happens every ≤600s no matter what `Expiration` says.

So the effective re-read interval is `min(600, REREAD_DELAY)`, and with
`REREAD_DELAY = 900` the observed cadence is **~600s / 10 minutes — tighter than the
15 minutes asked for.** `REREAD_DELAY` only becomes the binding constraint if set
below 600. Both bounds are therefore stated, and V9 records the measured interval
rather than asserting either number: litellm's 600s default is not configurable from
`litellm_config.yaml`, so it is an observation about the image, not a setting, and
`main-latest` can move it.

One consequence worth stating: re-reads are **lazy** — driven by a request arriving,
not by a clock. Idle proxy, no re-reads. That is not a gap: the first request after
any idle gap longer than the interval re-reads before it authenticates, because the
window has already elapsed. Credentials are only needed at request time, so a timer
firing into an idle process would buy nothing. The compose healthcheck is not such a
request: it runs `curl`, which the image lacks, so it never reaches `/health`
(measured 2026-09-23: `unhealthy`, the exec itself failing, 42 in a row). A client
that does call `/health` is one, since litellm's `/health` calls every model.

No expiry comparison and no floor: there is nothing in the file to compare
against, and a timestamp this far ahead is never in the past. The earlier
cap-and-floor formulation existed to force a re-read on *every* fetch — precisely
the behaviour this requirement replaces — so it is removed rather than tuned.

Consequences, stated plainly:

- During an expired window every request fails at AWS with
  `ExpiredTokenException`. That *is* the expiry detection; the container has no
  local means of detecting it, and does not need one.
- A refreshed file is picked up within `REREAD_DELAY`, with no restart.
- Re-read cost drops from one subprocess per request to one per
  `min(600, REREAD_DELAY)`, plus at most one per `ERROR_REREAD_COOLDOWN` while AWS
  is rejecting requests.
- Refresh now lands in botocore's *advisory* window rather than its 10-minute
  *mandatory* one, so an unreadable file no longer fails an advisory refresh of
  credentials botocore already holds: it logs a warning and keeps serving them. A
  fresh session has nothing to serve, so there an unreadable file still fails the
  request with HTTP 500. That happens after litellm's cache TTL or a cache drop. Acceptable exactly because the
  timestamp was never a validity claim — if those credentials are good the request
  succeeds, and if they are expired AWS rejects it. This reverses an earlier
  preference for the mandatory window, which assumed per-fetch re-reads.

### Trigger 2 — on error: re-read when AWS rejects the credentials

Trigger 1 alone means a person can refresh the file and still wait out the interval.
A credential rejection is the strongest signal available that re-reading is worth
doing, so it forces one.

**botocore will not do this by itself.** An `ExpiredTokenException` comes back from
the Bedrock call, long after credentials were resolved; botocore does not invalidate
them and retry. Something above it has to react.

The insertion point is litellm's failure hook. A `CustomLogger` subclass registered
in `litellm_settings.callbacks` implements
`async_post_call_failure_hook(request_data, original_exception, user_api_key_dict, traceback_str=None)`
(`custom_logger.py:452-470`), dispatched for every registered callback on LLM call
failure (`proxy/utils.py:3120-3141`). On a credential rejection it drops the cached
credentials so the next request re-resolves them — which, per Trigger 1's second
cache, means a fresh `boto3.Session` and a shim invocation, i.e. a file re-read.

Four constraints on that hook, each load-bearing:

- **Cooldown, or this becomes per-request churn.** During an expired window *every*
  request fails, so an unguarded hook would invalidate on every one of them and
  re-read the file per request — exactly the behaviour this plan exists to remove.
  At most one cache-drop attempt per `ERROR_REREAD_COOLDOWN` (default 60s) per
  worker process, held as a monotonic timestamp in the callback module. A burst of
  N failures produces one attempt; a successful drop makes the next request re-read,
  and a failed one re-reads nothing.
- **Narrow the trigger to credential rejections.** Match `ExpiredToken`,
  `ExpiredTokenException`, `InvalidClientTokenId`, `UnrecognizedClientException`.
  Not `AccessDeniedException` — that is a policy problem, and re-reading the file
  cannot fix a missing permission, so treating it as a refresh signal would re-read
  on every denied request forever.
- **Invalidate the cache litellm actually reads.** `BaseAWSLLM._shared_iam_cache` is
  a `ClassVar` `DualCache` shared process-wide (`base_aws_llm.py:227-241`), so
  `flush_cache()` (`dual_cache.py:500`) reaches every instance. Targeted
  `delete_cache(key)` would be neater but needs `get_cache_key(credential_args)`
  rebuilt from the deployment's args, which the hook does not reliably have; a flush
  costs at most one extra shim invocation per AWS deployment, so take the flush.
- **Failures here are silent.** litellm catches and logs exceptions from this hook
  and continues (`proxy/utils.py:3145-3148`). A wrong import path or a renamed
  attribute therefore yields a hook that never fires, with requests still working —
  the failure is invisible from the outside. V10 must prove it fires rather than
  assume it, and the hook must log its own no-op path (names and reasons only, never
  credential values).

This trigger depends on the same `AWS_PROFILE` choice as everything else: there is
only something to invalidate because the ambient-env path is cached. On the
`aws_profile_name` path litellm caches nothing, so there would be no handle to pull.

### Risk: private litellm internals on a moving tag

Trigger 2 reaches into `BaseAWSLLM._shared_iam_cache` — a private attribute, in an
image pinned to `main-latest`. A rename breaks the trigger **silently**, per the
point above. So the hook resolves it defensively (`getattr`, no bare attribute
access), logs loudly when it cannot find it, and V10 is re-run after any image
update. Trigger 1 keeps working regardless, which bounds the damage to "back to the
15-minute schedule" rather than "no refresh at all".

### Risk: `ADVISORY_WINDOW` is a botocore constant, not a contract

The formula hardcodes botocore's 15-minute advisory window
(`_advisory_refresh_timeout`). It has been 900s for years, but the image pins
`main-latest`, so its botocore can move. If that window ever **shrinks**, re-reads
happen later than `REREAD_DELAY` promises, silently — e.g. a 600s window with
`REREAD_DELAY = 60s` would re-read every 360s. V8 asserts the constant in the
running image, and the README must name the assumption.

## Risk: how the file is written, and torn reads under concurrency

Two risks share one root cause — the host script's write strategy — and they pull
in opposite directions, so they must be settled together.

**Inode replacement.** `docker-compose.yml:17` bind-mounts a single **file**
(`~/.env.aws`). Docker resolves that to an inode at container start, so replacing
the file on the host — `mv` into place, or delete and recreate — detaches the mount
from the live file. Not hypothetical: shell history contains `rm ~/.env.aws`.

Measured on this host (Rancher Desktop, Alpine VM, 2026-09-22) rather than assumed,
and the result is better than feared — the container does **not** go on serving the
old contents:

| host action | what the container sees |
| --- | --- |
| in-place rewrite (truncate) | new contents, same inode — works |
| `mv` replacement | `cat`: **No such file or directory** |
| `rm` + recreate | `cat`: **No such file or directory** |
| `docker compose restart` after either | new contents, new inode — recovered |
| `docker compose up -d` after either | reports `Running`, **still broken** |

So replacement fails **loudly and recoverably**, not silently, and the shim already
handles it: `cat` fails and it dies with `cannot read <path>` plus the recovery
command. Note that
`[ -r "$ENV_FILE" ]` returns *true* on a detached mount — the readability precheck
is not what catches this, the `cat` failure is, and the precheck must not be
trusted to.

That error reaches the operator rather than being buried: botocore carries a failing
credential process's stderr verbatim into `CredentialRetrievalError` (measured:
`Error when retrieving credentials from custom-process: aws-creds-shim: ...`), and
litellm builds a fresh session each cache TTL, so within ~600s of a replacement a
request fails with the shim's own message. The client sees it as HTTP 500,
`litellm.APIConnectionError`, carrying that text; `CredentialRetrievalError` appears
only in the container log.

Caveat on the measurement: that is the Mac file-sharing path. On native-Linux Docker
the classic pinned-inode semantics may apply instead, and replacement there *would*
be silently stale. Re-run V1 before running this setup on Linux.

**Torn reads.** If the host script truncates and rewrites in place, a concurrent
reader can observe a partial file. Truncated JSON is the benign case, caught by
"fail on missing field". The dangerous case is a **torn read where all three
fields are present but come from different generations** — a new `AccessKeyId`
paired with an old `SecretAccessKey`. That passes a presence check and would be
emitted as valid, producing a confusing signature failure rather than a clean
error. The delayed-re-read design shrinks this exposure considerably compared with
per-request reads: there is at most one reader per `min(600, REREAD_DELAY)` per
cache entry on the schedule, plus one per `ERROR_REREAD_COOLDOWN` while AWS is
rejecting requests, so the odds of landing inside a rewrite window are small. Small is not zero, and
the window is still only closed by an atomic replace on the writing side.

### Hard constraint: `$HOME` must never be mounted

`~/.env.aws` sits **directly in the home directory**, so "mount the containing
directory" would bind-mount all of `$HOME` into the container. That is ruled out
categorically, not weighed as a tradeoff. It would expose `~/.aws/credentials`,
`~/.ssh`, and `~/.midway/cookie` — and that cookie carries the ~20h Midway
session, which is *more* sensitive and longer-lived than the ~12h Bedrock
credentials the mount exists to deliver. Read-only does not help: the risk is
disclosure, not modification. Any option requiring a `$HOME` mount is rejected
regardless of what it buys.

So directory mounting is only available if the credentials live in a
**dedicated** directory holding nothing else.

### Resulting options

- **Preferred — dedicated directory + atomic replace (`mv`).** The host script
  writes into a directory created solely for this (e.g.
  `~/.config/litellm-proxy/`), and only that directory is mounted. Then every
  `open()` sees a complete, self-consistent file — torn reads impossible by
  construction — and inode replacement is visible. Resolves both risks without
  the shim needing to handle concurrency, and without exposing anything beyond
  the credentials themselves.

  Cost: the host script must write to the new path. Note `~/.zshrc:172` sources
  `~/.env.aws`, so that path has consumers outside this repo and cannot simply be
  moved — the script would need to write both locations, or the new path becomes
  the source and `~/.env.aws` a copy. Requires the script owner's agreement.

- **Fallback — keep the existing single-file mount, in-place rewrite.** No new
  path and no `$HOME` exposure, but atomic replace is unavailable (it would break
  the mount via inode replacement) and the torn-read window stays open. The shim
  must then reject *inconsistent* payloads, not merely incomplete ones: single-pass
  read plus a completeness marker written last, so a torn read is detectable.
  Also requires a host-script change, of comparable size to the preferred option.

Both paths need the script owner to change something, so the choice is not
"cheap vs expensive" — it is which guarantee is wanted. Prefer the dedicated
directory: it makes torn reads structurally impossible instead of detectable
after the fact.

**Decision, so tasks 3-5 are not blocked:** build tasks 3-5 on the **existing
single-file mount**, unchanged — it is already what the repo does
(`docker-compose.yml:17`), so nothing regresses, and replacement surfaces as a clear
per-request error naming its own fix rather than as indefinite silent staleness.
Recovery is `docker compose restart`, not `up -d`: on an unchanged config and image
`up -d` is a no-op — measured, it reports `Running` and leaves the mount detached.

That is a decision about **which mount to build against, not about what ships**. A
mount needing a manual restart after every refresh does not satisfy the operating
model above, so it cannot be the final answer if the writer replaces the inode.
Hence **V1 is a release gate, not a curiosity**:

- **Writer rewrites in place** → the single-file mount already meets the operating
  model in full, and no further mount work is needed.
- **Writer replaces the inode** (`mv`, delete-and-recreate, or most editors) → the
  single-file mount can only ever meet it with an operator restart, so the
  **dedicated directory becomes required** before this work is called done. It moves
  from "preferred follow-up" to a blocking task, and the plan is not complete until
  it lands.

So the dedicated directory is deferred only in *sequence*, never in *scope*: V1
decides whether it is unnecessary or mandatory. V1 has run: the writer rewrites in
place, so it is unnecessary. What it is **not** is optional — nothing here approves a
setup that needs a restart on every refresh.

The shim must also be safe under concurrent invocation in its own right: no
shared temp files, no lock files that can deadlock or leave stale locks. The V9
counter file is verification instrumentation only and must be removed afterwards,
not shipped.

## Tasks

1. `scripts/aws-creds-shim.sh` — read the mounted env file in a **single pass**,
   emit v1 JSON with `Expiration = now + ADVISORY_WINDOW + REREAD_DELAY`; exit
   non-zero with a stderr message if any of the three credential fields is
   missing or the file is unreadable. Because that stderr is what the operator
   actually sees (it arrives verbatim in `CredentialRetrievalError`), the read
   failure message must name the likely cause and the fix: the mount was detached
   by a host-side replacement, recover with `docker compose restart`. Safe under
   concurrent invocation: no shared temp or lock files. Never echo secret values to
   stderr or logs. `REREAD_DELAY` defaults to **900s** and must be validated and
   bounded to `[1, 900]` — an override able to exceed that would push the staleness
   bound past the 15 minutes the requirement sets.
   **Already implemented against the superseded cap-and-floor contract; this task is
   now a revision of an existing file, not new work.**
2. `scripts/aws-config` — single profile with `credential_process`. Done.
3. `docker-compose.yml` — mount shim, AWS config **and the callback module**, set
   `AWS_CONFIG_FILE` **and `AWS_PROFILE`**, and keep the existing single-file
   credentials mount. The callback is mounted beside `config.yaml`, not put on
   `PYTHONPATH`: litellm resolves a callback string against the config's directory
   first. Drop `env_file` entirely and pass through only the two `LITELLM_CREDS_*`
   settings by name, so `AWS_*` lines in an existing `.env` (the old sample had them)
   cannot reach the container. No `AWS_ACCESS_KEY_ID`,
   `AWS_SECRET_ACCESS_KEY` or `AWS_SESSION_TOKEN` may remain in the container
   environment: botocore's env provider outranks the profile and would shadow the
   shim entirely. Mounting `$HOME` (or any parent of it) is prohibited.
4. `scripts/aws_credential_refresh.py` — **new.** `CustomLogger` subclass
   implementing `async_post_call_failure_hook`, per trigger 2: match only the four
   credential-rejection codes, enforce `ERROR_REREAD_COOLDOWN` (default 60s) via a
   monotonic clock, resolve `BaseAWSLLM._shared_iam_cache` defensively and
   `flush_cache()` it. Must never raise into the caller's path, never log credential
   values, and log the reason whenever it declines to act (cooldown active at info,
   code not matched at debug with the exception type name only, cache attribute
   missing at error) — silent no-ops here are indistinguishable from success. Only
   the error line is visible without `--detailed_debug`. Expose a module-level instance for the config to reference.
5. `litellm_config.yaml` — register the callback under `litellm_settings.callbacks`.
   No model entry changes; verify no entry sets an `aws_*` credential param, since
   that is what keeps every model on the cached ambient-credentials branch — and
   trigger 2 has nothing to invalidate without it.
6. `entrypoint.sh` — reduce to `exec litellm`. This also removes the startup
   `source` of the credentials file, which is required, not incidental: those
   exported variables would otherwise shadow the profile.
7. `README.md` — document **both triggers**, quote the V9 measured re-read interval
   rather than the nominal 900s (it will be ~600s, and say why: litellm's
   non-configurable credential cache TTL), state the `ADVISORY_WINDOW = 900s`
   botocore assumption from V8, and state the constraint
   that adding an `aws_*` credential param to a model silently reverts to
   per-request re-reads and disables trigger 2. Record that trigger 2 depends on a
   private litellm attribute, so an image update warrants re-running V10. Document the single-file mount caveat as a **procedure**,
   not just a warning: if the credentials file is replaced rather than rewritten in
   place, requests fail with HTTP 500 (`litellm.APIConnectionError`) carrying the
   shim's message, and
   `docker compose restart` is the recovery — and say why `up -d` is not, since
   that is the command an operator will reach for first. If V1 shows the writer
   replaces the inode, that procedure is not the answer and the dedicated directory
   lands first (mount decision above); the README then documents the new path
   instead of a restart ritual.

## Verification

Runtime evidence required; source inspection is not sufficient.

Measurements and status live in
[VERIFICATION-credential-refresh.md](VERIFICATION-credential-refresh.md), not here.

- **V1 — inode behaviour. Release gate. PASS**, on Rancher Desktop. An in-place
  rewrite is visible to the container, and a replacement makes the mounted path
  unreadable until the container is restarted. The host refresh script rewrites in
  place, and on the real container the detached-mount failure surfaces as a request
  error carrying the shim's message. So the dedicated directory stays a follow-up.
  Re-run on native Linux if this ever moves there.
- **V9 — the scheduled interval, measured.** The central check for trigger 1. Have the
  shim append a timestamp to a counter file, issue N requests inside one interval, and
  confirm the invocation count is ~1, not N. Then run across several intervals and
  record the **actual** spacing. Expect ~600s, not 900s, per the two-cache analysis —
  and treat a measurement near 900s as evidence that litellm's cache TTL moved, which
  changes the documented bound. Anything ≤900s satisfies the requirement; the number
  goes in the README. Record the image digest: the cadence depends on internal litellm
  behaviour, not on config.
- **V10 — trigger 2 fires, and only when it should.** Four parts, because the hook
  fails silently (litellm swallows its exceptions). (a) With expired credentials in
  the file, issue one request, confirm it fails at AWS, then confirm a shim invocation
  follows the failure rather than the schedule — the counter advances on the **next
  request**, not 600s later. The flush is lazy: dropping the cache entry does not
  itself re-resolve anything, so there is no invocation to observe until something asks
  for credentials again. (b) Rewrite the file with valid credentials during an expired window and
  confirm the **next** request after the cooldown succeeds, well inside one scheduled
  interval; this is the whole point of the trigger. (c) Issue a burst of N failing
  requests inside one `ERROR_REREAD_COOLDOWN` and confirm exactly one extra
  invocation, not N — the cooldown is what stops this being per-request churn.
  (d) Provoke a non-credential failure (bad model name, or a policy
  `AccessDeniedException` if one can be arranged) and confirm **no** invalidation.
  Also confirm the hook logs its decisions and that no credential value appears in
  those logs.
- **V8 — the botocore advisory window really is 900s.** `docker exec` a read of
  `botocore.credentials.RefreshableCredentials._advisory_refresh_timeout` in the
  running image. If it is not 900, the emitted `Expiration` must be recomputed from
  the real value, because `REREAD_DELAY` silently stops being the interval.
  Record the botocore version alongside it.
- **V3 — no-restart pickup.** Record litellm's PID, rewrite `~/.env.aws` with
  valid fresh credentials, issue a request, confirm it succeeds **and** the PID
  is unchanged.
- **V4 — recovery after a prolonged expired window.** The primary scenario, per
  the operating model. Point the file at expired credentials, leave it expired
  across several request attempts, confirm each fails cleanly and the proxy stays
  up and does not restart-loop; then rewrite with valid credentials and confirm
  recovery with no restart and no operator action. Each failure must be AWS's own
  `ExpiredTokenException`, which confirms detection is happening at AWS and not
  locally. Recovery is bounded twice over: by `ERROR_REREAD_COOLDOWN` if any request
  was attempted after the rewrite (trigger 2), and by the scheduled interval
  regardless (trigger 1). Assert the **trigger 1 bound** here — V10(b) covers the
  faster path — so this verification still passes if trigger 2 is broken.
- **V4b — the profile is actually in use.** Regression guard for the shadowing
  trap. Assert no `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` or
  `AWS_SESSION_TOKEN` is present in the container environment, and that credentials
  resolve through the shim — evidenced by the V9 counter advancing at all. If the env
  vars survive, every other verification here passes for the wrong reason.

  Check **names only**:
  `docker compose exec litellm sh -c 'printenv | cut -d= -f1 | sort'`. Never a bare
  `env` or `printenv`: this assertion needs three names, but those print every value
  in the container — the litellm master key, the database URL, and any credentials
  that leaked in are exactly what is being looked for — into the terminal, this
  session's transcript, and any verification notes pasted from it. Same rule
  anywhere else the container environment is inspected.
- **V5 — malformed input.** Truncate the file mid-write; confirm the shim exits
  non-zero with a clear message and leaks no secret material.
- **V5b — torn read under concurrent load.** Drive concurrent requests while
  rewriting the file in a loop, and assert no request ever authenticates with a
  mismatched key pair: every request either succeeds with a consistent
  generation or fails cleanly. Under the preferred atomic-replace shape this
  should hold by construction; run it anyway, since it is the guard that proves
  the chosen shape actually delivers that.
- **V6 — baseline.** `curl -f http://localhost:8000/health` passes and a
  completion against `claude-sonnet-4-5` succeeds.
- **V7 — mount surface.** Inspect the running container's mounts and confirm that,
  apart from this repo's own files and `./logs`, the only host path exposed is the
  credentials file or its dedicated directory. Specifically assert `~/.aws`, `~/.ssh`
  and `~/.midway` are **not** reachable from inside the container.

## Open question — answered: the script rewrites in place

Settled empirically on 2026-09-23. After a real refresh at 09:01:48, the running
container's `/app/env.aws` hash-matched the host file with no restart in between, so
the single-file mount stays and the dedicated directory remains a follow-up, not a
required task. Evidence is in
[VERIFICATION-credential-refresh.md](VERIFICATION-credential-refresh.md#v1--what-the-real-container-showed).
Hand-editing the file in most editors still replaces the inode. The README covers
recovery from that.
