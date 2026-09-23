# Verification evidence: credential refresh

Evidence for the verifications listed in
[PLAN-credential-refresh.md](PLAN-credential-refresh.md#verification). Runtime
measurements only — a default read out of source does not count here.

**Measured on:** `ghcr.io/berriai/litellm:main-latest`, litellm 1.103.0, botocore
1.43.6, Rancher Desktop on macOS (darwin 25.6.0), 2026-09-22/23.

Two containers were used:

- **production** — `litellm-proxy` from `docker-compose.yml`, real credentials from
  `~/.env.aws`, host port 8000.
- **harness** — `litellm-verify` at `~/litellm-verify`, host port 8001, fabricated
  credentials, and a wrapper on the `credential_process` path that appends a timestamp
  to a counter file before exec'ing the real shim. The wrapper is a measurement device
  and does not ship.

| ID | What it proves | Status |
|---|---|---|
| V8 | The constants the design rests on are real | PASS |
| V4b | Credentials resolve through the profile, not the environment | PASS |
| V6 | Baseline: health and a real completion | PASS |
| V9 | The scheduled interval, measured | PASS — ~606s |
| V10a | Trigger 2 fires on a credential rejection | PASS on the invalid-credential path; expired-token end to end outstanding |
| V10c | The cooldown collapses a burst to one re-read | PASS |
| V10d | A non-credential failure does not invalidate | PASS |
| V10e | Matcher decision table, incl. `AccessDeniedException` | PASS |
| V7 | Beyond repo files and `./logs`, only the credentials file is exposed; nothing else from `$HOME` | PASS |
| V5 | Malformed input — 14 fixtures, host and in-container | PASS, after three fixes |
| V3 | Pickup without restarting the process | PASS |
| V5b | Torn read under concurrent load | PASS for key-pair consistency; truncated tokens rejected since review round 3; 1s stale view measured |
| V10b | Recovery after an in-place rewrite | PASS — 70s |
| V4 | Prolonged expired window, trigger-1 bound | blocked by VM memory; as predicted up to tr+389 |
| V1 | Inode behaviour against the real container. **Release gate** | PASS |

## V8 — the constants are real

Read out of the running image rather than out of botocore's source:

- `RefreshableCredentials._advisory_refresh_timeout` = **900** — the shim's
  `ADVISORY_WINDOW` matches, so `Expiration = now + 900 + REREAD_DELAY` does land
  inside the window and does cause re-invocation.
  - Since review round 2 the shim no longer hardcodes it: `entrypoint.sh` reads it
    at startup and exports `LITELLM_CREDS_ADVISORY_WINDOW`. In the image, 2026-09-23:
    the read logged `entrypoint: botocore advisory refresh window is 900s`; with
    `python` stubbed to fail it logged the `WARNING` and left the variable unset.
    Shim `Expiration - now` = window + `REREAD_DELAY`: 1800 with the variable unset,
    900 or empty; 1200 at 300; 360 at 300 with a delay of 60. `abc` and `0900` are
    rejected. The 14 V5 fixtures give output identical to the previous shim, with
    `Expiration` masked. Production after recreate at 02:50:29Z: litellm's PID 1 carries
    `LITELLM_CREDS_ADVISORY_WINDOW=900`, credentials resolve via `custom-process`,
    and a completion returned HTTP 200 in 1.33s.
- `RefreshableCredentials._mandatory_refresh_timeout` = **600**.
- `BaseAWSLLM._shared_iam_cache` is a `DualCache` with a callable `flush_cache`, and
  its `in_memory` `default_ttl` is **600** — the second cache in the series, and the
  one that turns out to govern the interval.
- `CustomLogger.async_post_call_failure_hook` takes
  `(request_data, original_exception, user_api_key_dict, traceback_str=None)` — the
  callback's signature matches.

## V4b — the profile is actually in use

`printenv | cut -d= -f1 | sort` inside the production container (names only — a bare
`env` prints every value) returns exactly `AWS_CONFIG_FILE`
and `AWS_PROFILE` from the `AWS_` family. No `AWS_ACCESS_KEY_ID`,
`AWS_SECRET_ACCESS_KEY` or `AWS_SESSION_TOKEN`, so botocore's environment provider
cannot shadow the profile. Corroborated by V9: the counter advances at all, which only
happens if `credential_process` is being consulted.

## V6 — baseline

`/health` passes on the production container and a `claude-haiku-4-5` completion
returns a real answer through port 8000, with credentials resolved by the shim.

## V9 — the scheduled interval is ~600s, not 900s

Run on the harness with `LITELLM_CREDS_ERROR_REREAD_COOLDOWN=100000`, so trigger 2
fires at most once and the schedule alone governs the rest. One request every 30s for
15 minutes; the counter was sampled after each.

```
t=1     invocations=1   <-- first resolution
t=31    invocations=2   <-- trigger 2, its one permitted firing
t=61 .. t=607           invocations=2   (20 requests, no re-read)
t=637   invocations=3   <-- scheduled re-read
t=667 .. t=880          invocations=3
```

**606s between re-reads** (t=31 to t=637), which is 600s within the 30s poll
granularity. So the effective interval is `min(600, LITELLM_CREDS_REREAD_DELAY)` =
600s, comfortably inside the 15 minutes required, and raising
`LITELLM_CREDS_REREAD_DELAY` above 600 changes nothing. This is a litellm cache TTL,
not a setting here, and the image tracks a moving tag — a future measurement near 900s
would mean the TTL moved and the README bound needs revisiting.

The 20 requests between t=61 and t=607 producing **zero** re-reads is also the "~1
invocation, not N" half of V9.

## V10a — trigger 2 fires on a credential rejection

Harness, fabricated credentials. One request returned
`litellm.AuthenticationError: BedrockException Invalid Authentication - {"message":"The
security token included in the request is invalid"}`, and the container logged:

```
LiteLLM Proxy:WARNING: aws_credential_refresh.py:181 - aws_credential_refresh: AWS
rejected the credentials in use; dropped the cached credentials so the next request
re-reads the credentials file.
```

That proves the callback resolves and loads from `/app/aws_credential_refresh.py`
beside `config.yaml`, the failure hook fires, the matcher works on the
*invalid*-credential path, and `flush_cache()` succeeded.

**Correction to the plan's wording for V10a**, since made in the plan: it expected "a
shim invocation follows the failure — the counter advances within seconds". The flush
is lazy, so the counter advances on the **next request**, not spontaneously after the
failure. Nothing re-resolves credentials until something asks for them. The former
plan text described the right mechanism with the wrong observable; V9's t=31 row is
that observable.

## V10c — the cooldown collapses a burst

Six further failing requests inside one 60s cooldown, starting from an armed cooldown:
counter went 1 → **2**, not 1 → 7, and exactly one callback log line for the whole
burst. The second request re-resolved (the cache had just been flushed) and the
remaining five hit the fresh cache entry. Without the cooldown this would be one
re-read per failed request, which during an expired window means every request.

## V10d — a non-credential failure does not invalidate

A request for `no-such-model-xyz` returned litellm's own 400
(`Invalid model name passed in model=...`). Counter unchanged and **no** new callback
log line. Since a successful flush logs at warning and warnings are visible at the
default level, the absence of that line is evidence no flush happened.

## V10e — matcher decision table

`_looks_like_credential_rejection` run directly against representative error strings
inside the container. All 12 correct:

- **Flush:** `ExpiredTokenException`, `ExpiredToken`, `InvalidClientTokenId`,
  `UnrecognizedClientException`, and the bare
  `BedrockException Invalid Authentication` message text.
- **Decline:** `AccessDeniedException`, `ThrottlingException`, `ValidationException`,
  `ModelNotReadyException`, `ServiceUnavailableException`, litellm's invalid model
  name, `litellm.Timeout`.

`AccessDeniedException` declining is the one that matters most: it means the
credentials were accepted and a *permission* was missing, which re-reading the file
cannot fix. Treating it as a refresh signal would re-read on every denied request
forever. It cannot be provoked with fabricated credentials — everything fails at
authentication first — so it is covered here rather than end-to-end.

## V7 — mount surface

Production container. `docker inspect` shows seven mounts: `config.yaml`,
`entrypoint.sh`, `aws-config`, `aws_credential_refresh.py`, `aws-creds-shim.sh` and
`env.aws` all read-only, plus `logs` read-write. The six besides `env.aws` are this
repo's own files and `./logs`. The only other host path from `$HOME` is `~/.env.aws`,
as a single file. Re-read after the recreate at 01:57:48Z (below): still seven, same
set.

From inside, none of `~/.aws`, `~/.ssh`, `~/.midway` exists under either `/root`
(the container's own `$HOME`) or `/app`, and `/` holds no host home tree. This is the
property the single-file mount buys, and the reason the inode fragility in V1 is worth
tolerating.

## V5 — malformed input, and one fix it forced

Fourteen fixtures (`~/shimtest-v2/fixtures/`, all values fabricated) run through the
real shim, twice. The last run was 2026-09-23 02:01Z, against the shim in this change
(uncommitted at the time):

- **On the host under `sh`**, while the Docker daemon was down (see the environment
  incident below). This needed a stub `date` on `PATH`, since the shim calls
  `date -u -d @EPOCH` and BSD `date` has no `-d`.
- **Inside the image**, where `/bin/sh`, `sed`, `tr` and `date` are all **BusyBox**
  (`/bin/sh -> /bin/busybox`, ash, not dash). Same 14 results as the host run, and
  `Expiration` came out at now + 1800s (1799s measured, within the second), as
  designed. This retires the host-shell
  caveat: BusyBox `sed` is the parser production actually runs.

Rejected cleanly — exit 1, a message naming the missing **variable** and the file, and
no secret material in it:

- `missing_token`, `empty_secret` — a name present but empty is treated as missing.
- `torn_midwrite` (file truncated mid-value), `empty_file`, `garbage`.
- `duplicate_no_trailing_newline` and `torn_midwrite`, since the third fix below —
  with `does not end with a newline` rather than a variable name.
- `space_after_equals` (`AWS_ACCESS_KEY_ID= ASIA...`) — the value is cut at the first
  whitespace, so it reads as empty and is rejected by name. Shell would not assign it
  either.

Accepted, emitting valid JSON:

- `plain`; `exported_quoted` (`export` prefix, both `"` and `'` quoting);
  `indented_with_extras` (leading whitespace, comments, unrelated `AWS_REGION`).
- `duplicate_no_trailing_newline` — **last assignment wins**, so a file containing an
  old and a new value of the same name yields the new one. Accepted until the third
  fix, which rejects it for the missing final newline; last-wins itself is unchanged.
- `inline_comment` (`...=VALUE # note`) and `trailing_whitespace` — the value stops at
  the whitespace.
- `special_chars` — the fabricated secret is `fake"quote\backslash`. It now comes out as
  `fake`: the value is cut at the first quote. Before the second fix below it
  round-tripped through `json_escape` intact. Real AWS values contain neither
  character, so no real input changes.

**The fix.** `crlf` originally produced **invalid JSON**: the parser left the carriage
return inside the value, and it was emitted as a raw control character inside a JSON
string. botocore would reject that with a parse error naming neither the file nor the
line ending — precisely the confusing failure `json_escape` exists to prevent. Fixed
with `tr -d '\r'` in `field()`, placed before the quote stripping so a trailing `\r`
cannot hide the closing quote. All 11 fixtures of the time passed after the change,
with no regression in the rejected set.

**The second fix**, from review: an inline `# comment` or trailing whitespace ended up
inside the value. `field()` now cuts the value at the first whitespace or quote
character after an optional opening quote. That one cut also drops the `\r`, so
`tr -d '\r'` was removed. `inline_comment`, `trailing_whitespace` and
`space_after_equals` were added for it; `crlf` still passes.

macOS is an unlikely source of CRLF, so this is a robustness fix rather than a live
bug — but it is one line, and it converts an undiagnosable failure into correct
behaviour.

**The third fix**, from review round 3: the shim now rejects a snapshot that does not
end with a newline, the torn-read signature measured in V5b below. In the image,
2026-09-23: of the 14 fixtures, `duplicate_no_trailing_newline` changed from accepted
to rejected and `torn_midwrite` from `AWS_SECRET_ACCESS_KEY missing` to the newline
message. The other 12 are identical to the previous shim, with `Expiration` masked:
7 accepted, 7 rejected. `empty_file` still reports `AWS_ACCESS_KEY_ID missing or
empty`, so the 1s empty view keeps its documented message. The real `~/.env.aws` ends
with a newline (checked by its last byte only). Production recreated at 03:08:22Z:
the shim exits 0 on the real file, credentials resolve via `custom-process`, and a
completion returned HTTP 200.

## V10b and V3 — in-place rewrite recovers in 70s, same process

Harness, default cooldown (60s), starting from fabricated credentials:

1. req1 failed at AWS, and the callback flushed the cache (01:21:32Z).
2. req2 re-read the fabricated file and failed; the cooldown declined to flush. The
   cache now held fabricated credentials.
3. The file was rewritten in place with the real credentials (`cat ~/.env.aws >`,
   inode 351763120 unchanged).
4. A request every ~5s: 403 from t+0 to t+64. The t+64 failure was the first outside
   the cooldown, so it flushed (01:22:37Z). **t+70: HTTP 200**, with exactly one extra
   shim run.

So the recovery bound after a rewrite is the cooldown plus one failed request, as the
README says: about a minute when requests keep arriving.

V3, same run, identity sampled before the rewrite and after the 200: host PID 5644,
PID 1 start time 7252298, container `StartedAt` 01:21:25Z and `RestartCount` 0 were all
unchanged. Pickup happened inside the running process.

## V5b — torn reads, and a 1s stale view

A host loop rewrote a file in place (`cat genX > file`), alternating two fabricated
generations: A (1025 bytes) and B (1425 bytes, longer token). The real shim read it
1500 times through a single-file bind mount in the image, which is the production
path. Each output was classified as consistent A, consistent B, clean error, or
anything else.

| Writer | Consistent | Clean error | Anything else |
|---|---|---|---|
| continuous, 5798 writes | 14 | 1486 | 0 |
| 5 writes/s, 194 writes | 415 | 803 | **282** |

The 282 all had every field from B but a session token cut to 905 characters. That is
B read up to **A's length**: 120 bytes of header plus 905 is 1025. So the container
reads new contents through a stale cached file size. The clean errors are the same
effect with a cached size of 0, captured between truncate and write.

The duration after a *single* rewrite, measured from inside the container at 5ms
intervals over 6 trials in both directions: an **empty read for 1.0s** (0.996-1.000s),
then the full new file. No trial showed the old or truncated contents after the
change.

What this means:

- **The property V5b asks for holds.** No output ever paired an access key with a
  secret from a different generation, in 3000 reads under stress.
- **With one rewrite per refresh**, the only exposure is a shim run inside that
  second. It fails cleanly (`AWS_ACCESS_KEY_ID missing or empty`), nothing is cached,
  and the next request reads the new file.
- **A truncated token needs two rewrites of different length within about 1s.** The
  token is non-empty and well-formed, so no presence check catches it. As first
  written, the shim emitted it, it failed at AWS as an invalid token, and trigger 2
  re-read within the cooldown. Review round 3 did not accept that as a bound, since
  the truncated credentials were cached and served until then. The snapshot ends
  mid-token, without the file's final newline, so the shim now rejects it on that.

Re-run 2026-09-23 with the same fabricated A/B generations, 1500 shim runs per row
through a single-file bind mount in the image. The harness was rebuilt, so the
truncation rate differs from the first run; the control row is the previous shim
under the same harness:

| Shim | Writer | Consistent | Clean error | Newline rejection | Truncated token emitted |
|---|---|---|---|---|---|
| previous (control) | 5 writes/s | 1362 | 134 | — | **4** (len 905) |
| newline check | 5 writes/s | 1364 | 135 | 1 | 0 |
| newline check | 5 writes/s | 1357 | 138 | 5 | 0 |
| newline check | continuous | 14 | 1485 | 1 | 0 |

The 1s figure is a Rancher Desktop (vz, virtiofs) property. Measure it again on any
other Docker runtime.

## Log hygiene

No credential value was printed at any point in this verification. Only variable
names, redacted values, and fabricated credentials (`ASIAFAKE…`,
`fakeSecret…`, `FAKESESSIONTOKEN…`) appear in any output. The counter file holds epoch
seconds only.

Grep of the logs, counting matches without printing them, with the real values taken
from `~/.env.aws` into a mode-600 temp file that was deleted afterwards:

| Source | Lines | Real values | Fabricated values |
|---|---|---|---|
| harness `docker logs` | 2172 | 0 | 0 |
| production `docker logs` | 202 | 0 | 0 |
| harness counter directory | — | 0 | — |

That closes V10's "no credential value appears in those logs". The harness figure
covers the whole V4 container. It held the real credentials from the rewrite at tc+122
until it stopped, and it was counted after the stop.
`--force-recreate` discarded the earlier harness containers' logs. There was no
application log to grep. `litellm_config.yaml` asks for JSON logs at
`/app/logs/litellm.log` (`success_callback`/`failure_callback: ["json"]`), but
production had written no such file after serving real completions. That setting was
already in the config before this work and was not investigated here.

## Log visibility, measured

`verbose_proxy_logger` sits at `NOTSET` and inherits root's `WARNING`, so of the
callback's four outcomes only two are visible by default: the flush (warning) and the
"could not invalidate, litellm internals moved" path (error). The "a cache drop was already
attempted" line (a rejection within the cooldown) is info and the "not a credential rejection" line is debug;
neither appears.

`LITELLM_LOG=INFO` does **not** reveal it: that variable sets the level of litellm's
*handler* (`_logging.py`, `log_level = os.getenv("LITELLM_LOG", "DEBUG")`), not of the
logger, and the logger filters first. `litellm --detailed_debug` is the lever
(`proxy_cli.py` → `_turn_on_debug()` → `verbose_proxy_logger.setLevel(DEBUG)`).

The callback's docstring and the README troubleshooting section were corrected to say
this, rather than raising the cooldown line to warning — during an expired window that
would emit one warning per failed request, on top of the error litellm already logs.

## V1 — what the real container showed

Two observations on production, both unplanned, settle V1. With the harness run on
replacing `env.aws` below, it passes.

**The host refresh script rewrites in place.** After a real refresh at 09:01:48 on
2026-09-23, `/app/env.aws` inside the container hash-matched `~/.env.aws` on the host
with no restart in between. That answers the plan's open question with the safe
answer: the single-file mount meets the operating model, and the dedicated directory
stays unnecessary. One refresh observed, not a guarantee about every future version
of that script.

**Every single-file mount detaches on replacement, not just `env.aws`.** Replacing
`scripts/aws-creds-shim.sh` on the host (the Edit tool writes a new file) detached the
shim's mount in the running container. Measured:

- every request failed with
  `FileNotFoundError: [Errno 2] No such file or directory: '/app/aws-creds-shim.sh'`
- `[ -e ]` and `[ -r ]` on the path still returned true
- the other five mounts were unaffected
- the shim's own "cannot read ... run 'docker compose restart'" message never appeared,
  because that message comes from the shim, and the shim is the missing file
- `docker compose restart` fixed it: shim readable, credentials VALID, a real
  completion answered

`git checkout -- <file>` also replaces the inode (measured in a scratch repo:
351756320 before, 351756395 after), so `git pull` on this repo can do the same to a
running proxy. A shell `>` redirect kept the inode. The README now says to run
`docker compose up -d --force-recreate` after editing or pulling, not `restart`: a pull
can also change `docker-compose.yml`, which `restart` does not apply.

**Replacing `env.aws` surfaces the shim's message to the client.** On the harness: one
failing request flushed the cache, then `mv` put a new inode over `env.aws` (351346399
to 351758111). Inside the container `[ -e ]` and `[ -r ]` stayed true while `cat`
failed. The next request returned **HTTP 500 in 5.0s**, and the shim ran 3 times
(litellm's retries). The client-facing body is:

```
litellm.APIConnectionError: Error when retrieving credentials from custom-process:
aws-creds-shim: cannot read /app/env.aws. If the host file was replaced rather than
rewritten in place ... run 'docker compose restart'
```

It contains the shim's text and the restart hint. `CredentialRetrievalError` appears
only in the container log, not in what the client sees, and the README's
troubleshooting lines now key on the text the client does see. The callback correctly
does not flush on this: it is not a credential rejection.

**Unexplained, not reproduced.** The first attempt at this, run straight after the
harness was recreated, did not fail in 5s. Three requests, started over about 2.5
minutes, all hung until 01:17:14Z and were released together; only then did the shim
run (9 times in 4s). The event loop was not blocked (`/health/liveliness` answered in
24ms during the hang), and the only processes in the container were litellm (PID 1)
and the probe itself — no shim, no `cat`. A clean re-run of the identical sequence took 5.0s. Releasing all
three together points at a shared stall, not per-request retries. It happened on a VM
that had been OOM-killing processes shortly before, which is the most likely factor,
but that is not shown. A second stall, in V4 below, hit with the VM at 52 MB available
and `docker exec` into the harness hanging as well. That places it in the VM rather than
in litellm. It still does not prove the cause.

## Environment incident: the Docker daemon

Correction to an earlier note: Rancher Desktop was **not** shutting down. The VM
(6 GiB, Kubernetes enabled, about 20 other containers) ran out of memory. The global
OOM killer took the harness (exit 137, `OOMKilled` true, 17:00:35Z on 2026-09-22) and
others. The ssh control master is a host process, so the VM's OOM killer cannot have
killed it. What is measured is that lima's current master socket dates from 23:00:08Z,
minutes after the retained kills below. The host's `~/.rd/docker.sock` is an `ssh -L`
forward that lima sets up once at boot and does not re-add to a new master, so the
socket went stale. Re-adding the forward through the live master restored it without
restarting Rancher.

The kernel log (a wrapped ring buffer, so only the latest kills) holds four global
OOM kills. Two were **production** litellm: host PIDs 2898 and 7459, in the
`litellm-proxy` cgroup, at about 22:50Z and 22:53Z on 2026-09-22. The other two were a
news-agg `headless_shell` and a `celery` worker. All of them predate production's
restart at 01:07:50Z. Production litellm uses 477 MiB with `oom_score_adj` 0, the
same as most of what runs beside it, so it is as likely a victim as anything else.

None of this is caused by the design. It does mean long harness runs can be killed
partway through. V4 ran the harness with `mem_limit: 1g` and `oom_score_adj: 1000`
(read back from `docker inspect`), so it is the first thing killed under pressure.

## V4, attempt 1 — blocked by VM memory

Setup:

- The harness was recreated with fabricated credentials and
  `LITELLM_CREDS_ERROR_REREAD_COOLDOWN=100000`, so trigger 2 fires once (req1) and never
  again.
- req2 re-read the fabricated file and filled the 600s cache at about tc+0.
- Every request failed for 120s.
- At tc+122 the real `~/.env.aws` was written in place into the harness copy.
- Polls followed every 20s.
- The expected first success is the first poll after the cache expires at about tc+600
  (tr+478), with the shim count going from 2 to 3.

What was measured:

- **tr+1 to tr+389: 20 polls, all 403, shim count flat at 2.** That matches the
  prediction. The cache had not expired yet, and trigger 2 stayed silent through every
  one of those rejections, so the 100000s cooldown held. The harness log for the whole
  run has exactly one flush line, from req1.
- **The polls started at tc+531 and tc+612 both hung for the full 60s client timeout**
  (HTTP 000). The shim count stayed at 2, although the second poll started after the
  cache had expired and should have re-read.
- A `docker exec` into the harness hung as well.
- The VM showed 62 MB free, 52 MB available, and no swap.
- The kernel log shows no OOM kill at that time.
- The run was stopped at 01:36:10Z. The container needed SIGKILL (exit 137) after
  `stop -t 5`. The harness copy of `env.aws` was put back to the fabricated file.

So the run says nothing about the trigger-1 bound: the stall started just before the
point it was meant to measure.

It cannot be re-run on this VM as it stands. With the harness stopped, the VM has
about 520 MB available. A second litellm needs about as much as production's 477 MiB,
which puts the VM back at the ~50 MB point where both stalls happened. A re-run needs
that headroom freed first: stop the news-agg stack, turn off Kubernetes, or give the VM
more memory.

## Production after the review fixes

Production was recreated with `docker compose up -d --force-recreate` at 01:57:48Z.
That applied the compose change (no `env_file`, two names passed through) and
reattached the shim mount, which an editor save had detached. Measured afterwards:

- **Environment**, names only: the only `AWS_*` names are `AWS_CONFIG_FILE` and
  `AWS_PROFILE`. Neither `LITELLM_CREDS_*` name is present, since there is no `.env`,
  so the defaults apply. Restart count is 0, and there are 7 mounts as in V7.
- **The pass-through itself** was measured in a scratch compose project with Compose
  v5.3.1 and a fabricated `.env`. A bare name in `environment:` took its value from
  `.env`. An unset name was absent from the container, not empty. `AWS_*` lines in
  the same `.env` did not reach the container.
- **The credential check** from Troubleshooting prints an ARN, resolved through the
  profile and the shim. A real completion returned HTTP 200 in 1.26s.
- **The callback's debug path**, run in the image against a synthetic exception, logs
  `BadRequestError is not a credential rejection; no re-read`. It carries the type name
  and not the message. The matcher still returns True for the expired and invalid
  texts and False for `AccessDeniedException`.
- **After the logging fixes from review round 2**, the same kind of run, with the
  logger at debug, drove three calls. A `ValueError` whose message held marker text
  logged `ValueError is not a credential rejection; no re-read`, and the marker did
  not appear. An `ExpiredTokenException` logged the flush line. A second one inside
  the cooldown logged the cooldown line. The broad `except` guard was not exercised:
  nothing in these inputs makes the hook raise.

## Outstanding

- **V4** — prolonged expired window; assert the trigger-1 bound specifically, so it
  still passes if trigger 2 is broken. Blocked on VM memory, see
  [V4, attempt 1](#v4-attempt-1--blocked-by-vm-memory). Pass: first 200 at the first
  poll after tr+478, within 900s of the rewrite, with 1 flush line and no restart.

All runs above used one image,
`ghcr.io/berriai/litellm@sha256:114aca7726c311915c8ea5120fcc44d32a0648c3ae3aec41a1014f0e846b16d1`,
in both production and the harness. The V9 cadence belongs to that digest: litellm
internals set it, not configuration.

Not reproducible here: the failures in V4, V10 and V5b use **invalid** fabricated
credentials, not expired real ones, so AWS answers "security token ... invalid", not
`ExpiredTokenException`. Both are AWS's own rejection, and V10e covers the matcher for
both. The expired case end to end is left to the first real expiry.

## Explained: re-reads with no requests from this verification

After the V9 poll loop stopped, the counter advanced twice more, 1439s and 1987s after
the last polled re-read. Neither gap is a multiple of 600s.

These were requests, just not ours. The harness access log around both timestamps
shows other clients on the host calling port 8001: `GET /health`, `GET /v1/models`,
`GET /api/v1/health`, `POST /v1/embeddings` and `POST /v1/chat/completions`. litellm's
`/health` calls every configured model, and each call looks up credentials. So each
re-read landed on the next request after the 600s cache had expired, which matches
the V9 mechanism. There is no background task.

This only affects the V9 figure if such traffic falls inside a measurement window. It
did not during V9 itself: 20 polled requests produced zero re-reads between t=61 and
t=607. It does mean something on this machine probes local ports for LLM endpoints,
which bears on the proxy being reachable without a key.
