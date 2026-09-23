# LiteLLM Proxy Local Setup

## Prerequisites

- Docker and Docker Compose installed
- AWS credentials with Bedrock access in `~/.env.aws`, in shell format:

```bash
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
AWS_SESSION_TOKEN=...
```

`export` prefixes, quotes, full-line and inline comments, trailing whitespace, unrelated
variables and CRLF line endings are all accepted, and a repeated name takes its last
value. Do not export these into your own shell and expect the container to see them.
`AWS_*` lines in `.env` are ignored. See [Credential refresh](#credential-refresh).

## Quick Start

1. Create logs directory:

```bash
mkdir -p ./logs
```

2. Start the proxy:

```bash
docker compose up -d
```

3. Check health:

```bash
curl http://localhost:8000/health
```

## Available Models

| Model Name | Bedrock Model ID |
|------------|------------------|
| claude-sonnet-4-5 | anthropic.claude-sonnet-4-5-20250929-v1:0 |
| claude-haiku-4-5 | anthropic.claude-haiku-4-5-20251001-v1:0 |
| claude-opus-4-5 | anthropic.claude-opus-4-5-20251101-v1:0 |

## Testing

```bash
curl --location 'http://localhost:8000/chat/completions' \
--header 'Content-Type: application/json' \
--data '{
  "model": "claude-sonnet-4-5",
  "messages": [
    {
      "role": "user",
      "content": "Hello, what model are you?"
    }
  ]
}'
```

## Configuration

- **Config file**: `litellm_config.yaml`
- **Logs**: `./logs/litellm.log` is configured (JSON, success and failure), but on
  litellm 1.103.0 nothing was written there after real completions (2026-09-23, not
  investigated). `docker logs litellm-proxy` is the log that works.
- **Port**: 8000 (host) -> 4000 (container)

## Credential refresh

Refreshing the credentials themselves needs a person, so this setup does not try to
automate it. What it does is make the **running** proxy pick up a rewritten
`~/.env.aws` without a restart.

`~/.env.aws` is mounted read-only into the container. botocore resolves credentials
through the `bedrock` profile in `scripts/aws-config`, whose `credential_process` is
`scripts/aws-creds-shim.sh`; the shim reads the mounted file and emits JSON. Because
that hook is called *while the process runs*, refreshed credentials need no restart.

Two things trigger a re-read:

| Trigger | When | Limit |
|---|---|---|
| Scheduled | The first request once the interval has passed | `LITELLM_CREDS_REREAD_DELAY`, default 900s |
| AWS rejected the credentials | The request after a credential rejection | One cache drop per `LITELLM_CREDS_ERROR_REREAD_COOLDOWN`, default 60s |

So after you refresh `~/.env.aws` because the old credentials expired, requests keep
failing until one fails with the cooldown clear — 60s after the last drop, which
during an expired window is at most a minute ago. That failure drops the cache, and
the request after it uses the new credentials, unless it lands within about a second
of the rewrite, when Rancher Desktop can show the file empty (see Common Issues).
Measured: 70s from an in-place rewrite to the first success, in the same process. If you refresh while the old credentials
still work, nothing fails, so only the scheduled re-read picks up the new file:
within 900s, about 600s today (below).

Things worth knowing before changing any of this:

- **The scheduled interval is shorter than 900s — measured at ~600s.** litellm caches
  resolved AWS credentials for 600s and rebuilds the boto3 session on a miss, which
  re-runs the shim regardless of what the shim emitted. The effective interval is
  `min(600, LITELLM_CREDS_REREAD_DELAY)`, so raising the variable above 600 changes
  nothing. Measured on litellm 1.103.0 by polling every 30s: consecutive re-reads
  606s apart, which is 600s within the poll granularity. That 600s is a litellm
  default, not a setting here, and the image tracks `main-latest` — it can move, so
  treat 900s as the guarantee and 600s as today's behaviour.
- **The emitted `Expiration` is a re-read schedule, not a validity claim.** The shim
  has nothing to derive real expiry from (`~/.env.aws` carries no expiry field), and
  AWS is the authority on whether credentials work. Expired credentials fail at AWS
  with `ExpiredTokenException`; that *is* the detection.
- **It assumes botocore's advisory refresh window is 900s.** The shim places
  `Expiration` at `now + 900 + REREAD_DELAY` so that the remaining lifetime lands
  inside that window and botocore re-invokes it. If a future botocore changes the
  window, re-reads happen on a different interval than the variable says.
- **Never put AWS credentials in the container environment.** botocore's
  environment provider outranks the profile, so a stray `AWS_ACCESS_KEY_ID` — even
  empty — silently wins, the shim is never called, and the proxy is pinned to
  startup-time credentials. `docker-compose.yml` no longer loads `.env` wholesale: it
  passes through only `LITELLM_CREDS_REREAD_DELAY` and
  `LITELLM_CREDS_ERROR_REREAD_COOLDOWN`, so `AWS_*` lines left in an old `.env` are
  inert. Adding one to `environment:` in the compose file or an override brings the
  problem back. The flip side is that any *other* setting kept in `.env` must also be
  added to `environment:` by name, or it never reaches the container. Proxy auth is
  not one of those today: `litellm_config.yaml` declares `master_key` empty, which
  outranks `LITELLM_MASTER_KEY`, so auth is off with or without `.env` (measured on
  1.103.0). To enable it, set `master_key: os.environ/LITELLM_MASTER_KEY` and pass
  that name through. Check with names only:

```bash
docker compose exec litellm sh -c 'printenv | cut -d= -f1 | sort' | grep '^AWS_'
```

  Expect only `AWS_CONFIG_FILE` and `AWS_PROFILE`. Do not run a bare `env` or
  `printenv` — it prints every value in the container.
- **Do not add `aws_access_key_id`, `aws_secret_access_key`, `aws_session_token` or
  `aws_profile_name` to a model in `litellm_config.yaml`.** Those switch litellm to a
  code path that caches nothing, which removes the schedule and leaves the failure
  callback with nothing to invalidate. Region is fine.
- **The error trigger uses a private litellm attribute**
  (`BaseAWSLLM._shared_iam_cache`). If an image update renames it, the callback logs
  an error and the scheduled re-read carries on alone — worth re-checking after an
  image update.

### If the credentials file is replaced instead of rewritten

`~/.env.aws` is mounted as a single file, deliberately: it sits directly in `$HOME`,
so mounting its directory would expose `~/.aws`, `~/.ssh` and `~/.midway` to the
container.

The cost is that Docker resolves that mount to an inode at container start. If the
host file is **replaced** — `mv` into place, delete and recreate, or saved by most
editors — the mount detaches, and requests fail with HTTP 500:

```
litellm.APIConnectionError: Error when retrieving credentials from custom-process:
aws-creds-shim: cannot read /app/env.aws. If the host file was replaced ...
```

Recover with:

```bash
docker compose restart
```

`docker compose up -d` will **not** fix it: with unchanged config and image it is a
no-op and reports the container as `Running`. Rewriting the file in place (truncate
and write) avoids the problem entirely.

### After editing or pulling this repo

The same applies to every file this repo mounts singly — `scripts/aws-creds-shim.sh`,
`scripts/aws-config`, `scripts/aws_credential_refresh.py`, `litellm_config.yaml`,
`entrypoint.sh`. `git checkout`, `git pull` and many editors write a new file rather
than rewriting the old one, so the running container keeps the detached original. A
pull can also change `docker-compose.yml` itself, and `docker compose restart` does not
apply that: it reattaches the mounts but keeps the old service definition. So after
editing or pulling, run:

```bash
docker compose up -d --force-recreate
```

**The first start after upgrading to this version must use it**, since the upgrade adds
mounts and environment variables that a restarted container would not have.

The shim is the one that hurts: once its mount detaches, every request fails with

```
FileNotFoundError: [Errno 2] No such file or directory: '/app/aws-creds-shim.sh'
```

even though `ls` inside the container still shows the file. The shim's own
diagnostic message cannot appear, because the shim is what is missing.

## Logs

View logs:

```bash
# Docker logs
docker logs litellm-proxy

# Application logs -- currently empty, see Configuration above; these work only
# once the JSON logger writes
cat ./logs/litellm.log
cat ./logs/litellm.log | jq 'select(.status == "failure")'
```

## Troubleshooting

### Check if AWS credentials are valid

This resolves credentials the same way the proxy does — through the profile and the
shim — so it also tells you whether the shim itself is working:

```bash
docker compose exec litellm python -c "
import boto3
try:
    print(boto3.client('sts').get_caller_identity()['Arn'])
except Exception as e:
    print('NOT valid:', e)
"
```

`NOT valid: Error when retrieving credentials from custom-process: aws-creds-shim: ...`
means the shim failed, and the rest of the message says why. Run the shim directly to
see it in isolation (it prints credentials, so redirect it):

```bash
docker compose exec litellm /app/aws-creds-shim.sh > /dev/null
```

### Did the error trigger fire?

```bash
docker compose logs litellm | grep aws_credential_refresh
```

A line saying the cached credentials were dropped means it fired. A line saying it
could not invalidate them means litellm's internals moved and only the scheduled
re-read is left. Both are visible by default.

Two lines are *not* visible by default, because `verbose_proxy_logger` inherits root's
`WARNING`:

- "a cache drop was already attempted", logged at info when a rejection arrives
  within the cooldown
- "not a credential rejection", logged at debug with the exception type name only. Look
  for it if AWS rejections stop triggering a re-read.

`LITELLM_LOG=INFO` does not reveal either of them — that variable sets the handler
level, not the logger's. Add `--detailed_debug` to the `litellm` command in
`entrypoint.sh` if you need them.

### Common Issues

- **Container exits immediately**: Check `docker logs litellm-proxy` for errors
- **AWS auth errors after a refresh**: Expected until one request fails after the
  cooldown (`LITELLM_CREDS_ERROR_REREAD_COOLDOWN`, 60s) has passed since the last
  cache drop; the request after that succeeds. Measured 70s end to end — see
  [Credential refresh](#credential-refresh). If they persist, check for AWS
  credentials leaking into the container environment (the `printenv` check above).
- **HTTP 500, `aws-creds-shim: cannot read /app/env.aws`**: the credentials file was
  replaced rather than rewritten; run `docker compose restart`.
- **HTTP 500, `aws-creds-shim: AWS_ACCESS_KEY_ID missing or empty`, right after a
  refresh**: on Rancher Desktop the container sees the file as empty for about a
  second after each in-place rewrite. Nothing is cached, so retrying succeeds. If it
  persists, the file really is missing that line.
- **`FileNotFoundError: ... '/app/aws-creds-shim.sh'`**: the shim was edited or
  pulled on the host, which detached its mount; run
  `docker compose up -d --force-recreate`. See
  [After editing or pulling this repo](#after-editing-or-pulling-this-repo).
- **Port conflict**: Change the host port in `docker-compose.yml` if 8000 is in use

## Stop the Proxy

```bash
docker compose down
```
