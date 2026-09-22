# Plan: fast pickup of refreshed AWS credentials

**Status:** proposed
**Date:** 2026-09-22
**Revised:** 2026-09-22 — re-reads are now delayed rather than per-request, at the
owner's direction. This reversed two earlier choices: `aws_profile_name` gave way
to `AWS_PROFILE`, and the short-capped `Expiration` gave way to one placed beyond
botocore's advisory window. Tasks 1 and 4 changed as a result.
**Scope:** make the running proxy observe a rewritten `~/.env.aws` **without a
process restart**, instead of up to 300s later plus a restart. Re-reads happen on
a bounded delay rather than per request: `REREAD_DELAY` is both the interval
between re-reads and the worst-case lag between a person rewriting the file and
the proxy using it.

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
- Re-reading the file on every request during that window is pure churn — nothing
  the container can do makes expired credentials work, and only a person can
  change that. So the file is re-read on a **delay**, at most once per
  `REREAD_DELAY`, not once per failed request.

One precondition on the no-operator-action property, stated here because it
constrains the whole design: it holds when the file is rewritten **in place**. A
writer that *replaces* the file detaches the bind mount, and no container-side work
can recover from that — it takes either one manual restart or a different mount
shape. Which of the two the host script does is the open question below, and it
gates calling this work done.

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
- **`litellm_config.yaml`** is left unchanged — see below; the absence of
  `aws_*` credential params is what selects the right code path.
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

### `Expiration` is the re-read schedule

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

`REREAD_DELAY` is then exactly the re-read interval, and hence the worst-case lag
between a person rewriting the file and the proxy using it. Implemented as
`REREAD_DELAY = 60s`, overridable and bounded to `[1, 600]`.

No expiry comparison and no floor: there is nothing in the file to compare
against, and a timestamp this far ahead is never in the past. The earlier
cap-and-floor formulation existed to force a re-read on *every* fetch — precisely
the behaviour this requirement replaces — so it is removed rather than tuned.

Consequences, stated plainly:

- During an expired window every request fails at AWS with
  `ExpiredTokenException`. That *is* the expiry detection; the container has no
  local means of detecting it, and does not need one.
- A refreshed file is picked up within `REREAD_DELAY`, with no restart.
- Re-read cost drops from one subprocess per request to one per `REREAD_DELAY`.
- Refresh now lands in botocore's *advisory* window rather than its 10-minute
  *mandatory* one, so an unreadable file no longer fails the request: botocore
  logs a warning and keeps serving what it holds. Acceptable exactly because the
  timestamp was never a validity claim — if those credentials are good the request
  succeeds, and if they are expired AWS rejects it. This reverses an earlier
  preference for the mandatory window, which assumed per-fetch re-reads.

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
handles it: `cat` fails and it dies with `failed to read <path>`. Note that
`[ -r "$ENV_FILE" ]` returns *true* on a detached mount — the readability precheck
is not what catches this, the `cat` failure is, and the precheck must not be
trusted to.

That error reaches the operator rather than being buried: botocore carries a failing
credential process's stderr verbatim into `CredentialRetrievalError` (measured:
`Error when retrieving credentials from custom-process: aws-creds-shim: ...`), and
litellm builds a fresh session each cache TTL, so within ~600s of a replacement a
request fails with the shim's own message.

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
per-request reads: there is at most one reader per `REREAD_DELAY` per cache entry,
so the odds of landing inside a rewrite window are small. Small is not zero, and
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
decides whether it is unnecessary or mandatory, and until V1 runs, this plan is
provisional on the answer. What it is **not** is optional — nothing here approves a
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
   stderr or logs. The
   `REREAD_DELAY` override must be validated and bounded — an override able to
   exceed `[1, 600]` would make the staleness bound the delay exists to define
   arbitrarily large. **Already implemented against the superseded cap-and-floor
   contract; this task is now a revision of an existing file, not new work.**
2. `scripts/aws-config` — single profile with `credential_process`. Done.
3. `docker-compose.yml` — mount shim and config, set `AWS_CONFIG_FILE` **and
   `AWS_PROFILE`**, keep the existing single-file credentials mount, and stop
   supplying AWS credentials via `env_file`. No `AWS_ACCESS_KEY_ID`,
   `AWS_SECRET_ACCESS_KEY` or `AWS_SESSION_TOKEN` may remain in the container
   environment: botocore's env provider outranks the profile and would shadow the
   shim entirely. Mounting `$HOME` (or any parent of it) is prohibited.
4. `litellm_config.yaml` — **no change.** Verify only that no entry sets an
   `aws_*` credential param, since that is what keeps every model on the cached
   ambient-credentials branch.
5. `entrypoint.sh` — reduce to `exec litellm`. This also removes the startup
   `source` of the credentials file, which is required, not incidental: those
   exported variables would otherwise shadow the profile.
6. `README.md` — document the mechanism, quote the V9 measured re-read interval
   and name `REREAD_DELAY` as the worst-case pickup lag, state the
   `ADVISORY_WINDOW = 900s` botocore assumption from V8, and state the constraint
   that adding an `aws_*` credential param to a model silently reverts to
   per-request re-reads. Document the single-file mount caveat as a **procedure**,
   not just a warning: if the credentials file is replaced rather than rewritten in
   place, requests fail with `CredentialRetrievalError` naming the shim, and
   `docker compose restart` is the recovery — and say why `up -d` is not, since
   that is the command an operator will reach for first. If V1 shows the writer
   replaces the inode, that procedure is not the answer and the dedicated directory
   lands first (mount decision above); the README then documents the new path
   instead of a restart ritual.

## Verification

Runtime evidence required; source inspection is not sufficient.

- **V1 — inode behaviour. Release gate.** Partly answered above, measured on Rancher
  Desktop: an in-place rewrite is visible to the container, and a replacement makes
  the mounted path unreadable until the container is recreated. What remains is which
  of the two the host refresh script does, and a re-run on native Linux if this ever
  moves there. Repeat against the real litellm container once it is up, and confirm
  the detached-mount failure surfaces as a request error carrying the shim's message.
  A "replaces" result makes the dedicated directory a required task, per the mount
  decision above; this verification therefore cannot be skipped or deferred past
  completion.
- **V9 — the delay is real: re-reads are not per request.** The central check for
  this requirement. Have the shim append a timestamp to a counter file, issue N
  requests well inside one `REREAD_DELAY`, and confirm the invocation count is ~1,
  not N. Then run for several delay periods and confirm the interval between
  invocations is `REREAD_DELAY`, not shorter. Record the image digest, since the
  cache this relies on is internal litellm behaviour.
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
  the **next** request issued after one `REREAD_DELAY` succeeds, with no restart
  and no operator action. Each failure must be AWS's own `ExpiredTokenException`,
  which confirms detection is happening at AWS and not locally.
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
- **V7 — mount surface.** Inspect the running container's mounts and confirm the
  only host path exposed is the credentials file or its dedicated directory.
  Specifically assert `~/.aws`, `~/.ssh` and `~/.midway` are **not** reachable
  from inside the container.

## Open question

**The write strategy of the host refresh script** — in-place rewrite, or inode
replacement (`mv`, delete-and-recreate)? Only the first is safe on a single-file bind
mount. Note that hand-editing the file in most editors also replaces the inode.

This does not block tasks 3-5, which build against the existing mount either way. It
does gate **completion**: it is the input to V1, and per the mount decision a
"replaces" answer makes the dedicated directory a required task rather than a
follow-up. So the plan cannot be signed off without it.

Searching the machine did not find the script (`~/bin`, `~/.local/bin`, shell config,
and history all show only reads of `~/.env.aws`, plus one `rm`), so it cannot be read
rather than guessed — its owner has to answer. Failing that, V1 can be settled
empirically: refresh once for real, then check whether the mounted path inside the
container is still readable.
