#!/bin/sh
# botocore credential_process provider: turns the shell-format credentials file
# written on the host into credential_process v1 JSON, so a running litellm picks
# up refreshed credentials without a restart.
set -eu

ENV_FILE="${LITELLM_AWS_ENV_FILE:-/app/env.aws}"

# botocore's advisory refresh window
# (RefreshableCredentials._advisory_refresh_timeout). Once the remaining lifetime of
# the emitted credentials falls inside this window, botocore re-invokes this shim on
# the next credential use -- which is the only reason a re-read happens at all. It
# has been 900s for years, but the image tracks a moving tag, so V8 asserts it
# against the running container.
ADVISORY_WINDOW=900

# Interval between scheduled re-reads, and therefore the worst-case lag between a
# person rewriting ENV_FILE and the proxy using the new contents. Placing Expiration
# this far *beyond* the advisory window is what sets the interval.
#
# The emitted Expiration is a re-read schedule, not a validity claim: AWS stays the
# sole authority on whether the credentials work. Nothing here can make expired
# credentials succeed, and nothing here needs to -- a request with expired
# credentials fails at AWS with ExpiredTokenException, which is the detection.
#
# 900s implements the 15-minute requirement. The interval actually observed is
# shorter: litellm caches these credentials for 600s and builds a fresh boto3
# session on a miss, which re-runs this shim regardless of Expiration. So the
# effective cadence is min(600, REREAD_DELAY).
REREAD_DELAY="${LITELLM_CREDS_REREAD_DELAY:-900}"

# The upper bound is the requirement itself -- a larger value would push the
# staleness bound past the 15 minutes this exists to guarantee.
REREAD_DELAY_MAX=900
REREAD_DELAY_MIN=1

die() {
  printf 'aws-creds-shim: %s\n' "$1" >&2
  exit 1
}

# Rejected rather than clamped: this is static misconfiguration, and a warning on
# stderr would likely be swallowed by botocore and go unnoticed. An *empty* override
# is treated as unset by the `:-` above and takes the default, which is the friendlier
# reading of `LITELLM_CREDS_REREAD_DELAY=` left blank in an env file; the '' branch
# below is therefore unreachable today and kept only so that switching to `${VAR-...}`
# cannot silently produce `[ "" -ge 1 ]`.
case "$REREAD_DELAY" in
  '' | *[!0-9]*) die "LITELLM_CREDS_REREAD_DELAY must be a positive integer, got: $REREAD_DELAY" ;;
  0*) die "LITELLM_CREDS_REREAD_DELAY must not be zero or zero-padded, got: $REREAD_DELAY" ;;
esac
[ "$REREAD_DELAY" -ge "$REREAD_DELAY_MIN" ] ||
  die "LITELLM_CREDS_REREAD_DELAY must be >= $REREAD_DELAY_MIN, got: $REREAD_DELAY"
[ "$REREAD_DELAY" -le "$REREAD_DELAY_MAX" ] ||
  die "LITELLM_CREDS_REREAD_DELAY must be <= $REREAD_DELAY_MAX, got: $REREAD_DELAY"

# One snapshot, and every field is parsed from it, so a concurrent rewrite cannot
# hand back an access key and a secret key from different generations. This
# narrows the torn-read window but does not close it; only an atomic replace on
# the writing side does that.
#
# This read is also the only reliable detector of a detached bind mount: measured on
# Rancher Desktop, `[ -r "$ENV_FILE" ]` returns true after the host file is replaced,
# while reading it fails. So there is no readability precheck -- it would report
# success on exactly the case worth catching. botocore surfaces this message verbatim
# in CredentialRetrievalError, so it names the cause and the fix.
CONTENTS=$(cat -- "$ENV_FILE" 2>/dev/null) || die "cannot read $ENV_FILE. If the host file was replaced rather than rewritten in place (mv, rm and recreate, or most editors), the bind mount is detached and only restarting or recreating the container reattaches it: run 'docker compose restart'. Note 'docker compose up -d' will not fix it -- on unchanged config and image it is a no-op and reports the container as Running."

# Last assignment wins, so a file holding an old and a new value of the same name
# yields the new one. After an optional opening quote, the value is cut at the first
# whitespace or quote character. AWS credential values contain neither, so that one
# cut drops a closing quote, trailing whitespace, an inline "# comment", and the "\r"
# of a CRLF-written file. Measured: before CRLF was handled, the carriage return was
# emitted as a raw control character in the JSON, which botocore rejects with a parse
# error that names neither this file nor the line ending.
field() {
  printf '%s\n' "$CONTENTS" |
    sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$1=//p" |
    tail -n 1 |
    sed -e "s/^[\"']//" -e "s/[\"'[:space:]].*//"
}

# JSON string escape. Base64-ish AWS values contain neither, but emitting
# malformed JSON on a surprising value would be a confusing failure.
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

ACCESS_KEY_ID=$(field AWS_ACCESS_KEY_ID)
SECRET_ACCESS_KEY=$(field AWS_SECRET_ACCESS_KEY)
SESSION_TOKEN=$(field AWS_SESSION_TOKEN)

# Names only, never values.
[ -n "$ACCESS_KEY_ID" ] || die "AWS_ACCESS_KEY_ID missing or empty in $ENV_FILE"
[ -n "$SECRET_ACCESS_KEY" ] || die "AWS_SECRET_ACCESS_KEY missing or empty in $ENV_FILE"
[ -n "$SESSION_TOKEN" ] || die "AWS_SESSION_TOKEN missing or empty in $ENV_FILE"

# No expiry is read from the file: it does not carry one (inspected 2026-09-22), and
# the emitted timestamp schedules re-reads rather than describing validity. A value
# this far ahead is also never in the past, so it can never trip botocore's
# "refreshed credentials are still expired" RuntimeError while the file legitimately
# holds expired credentials.
NOW_EPOCH=$(date -u +%s)
EXPIRY_EPOCH=$((NOW_EPOCH + ADVISORY_WINDOW + REREAD_DELAY))
EXPIRATION=$(date -u -d "@$EXPIRY_EPOCH" +%Y-%m-%dT%H:%M:%SZ)

printf '{"Version":1,"AccessKeyId":"%s","SecretAccessKey":"%s","SessionToken":"%s","Expiration":"%s"}\n' \
  "$(json_escape "$ACCESS_KEY_ID")" \
  "$(json_escape "$SECRET_ACCESS_KEY")" \
  "$(json_escape "$SESSION_TOKEN")" \
  "$EXPIRATION"
