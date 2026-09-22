#!/bin/sh
# botocore credential_process provider: turns the shell-format credentials file
# written on the host into credential_process v1 JSON, so a running litellm picks
# up refreshed credentials without a restart.
set -eu

ENV_FILE="${LITELLM_AWS_ENV_FILE:-/app/env.aws}"

# The emitted Expiration decides when botocore next re-reads ENV_FILE; it is not
# a claim about how long the credentials are valid. 120s sits inside botocore's
# 15-minute advisory refresh window, so a re-read is attempted continuously, and
# inside the 10-minute mandatory window, so an unreadable file fails the request
# instead of silently serving stale credentials.
CAP_SECONDS="${LITELLM_CREDS_CAP_SECONDS:-120}"

# Upper bound of the mandatory window. Past it both properties above are lost, so
# an override may not exceed it -- the cap is the whole staleness guarantee.
CAP_SECONDS_MAX=600

die() {
  printf 'aws-creds-shim: %s\n' "$1" >&2
  exit 1
}

# Rejected rather than clamped: this is static misconfiguration, and a warning on
# stderr would likely be swallowed by botocore and go unnoticed.
case "$CAP_SECONDS" in
  '' | *[!0-9]*) die "LITELLM_CREDS_CAP_SECONDS must be a positive integer, got: $CAP_SECONDS" ;;
  0*) die "LITELLM_CREDS_CAP_SECONDS must not be zero or zero-padded, got: $CAP_SECONDS" ;;
esac
[ "$CAP_SECONDS" -le "$CAP_SECONDS_MAX" ] ||
  die "LITELLM_CREDS_CAP_SECONDS must be <= $CAP_SECONDS_MAX, got: $CAP_SECONDS"

[ -r "$ENV_FILE" ] || die "credentials file not readable: $ENV_FILE"

# One snapshot, and every field is parsed from it, so a concurrent rewrite cannot
# hand back an access key and a secret key from different generations. This
# narrows the torn-read window but does not close it; only an atomic replace on
# the writing side does that.
CONTENTS=$(cat -- "$ENV_FILE") || die "failed to read $ENV_FILE"

field() {
  printf '%s\n' "$CONTENTS" |
    sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$1=//p" |
    tail -n 1 |
    sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}

# JSON string escape. Base64-ish AWS values contain neither, but emitting
# malformed JSON on a surprising value would be a confusing failure.
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

ACCESS_KEY_ID=$(field AWS_ACCESS_KEY_ID)
SECRET_ACCESS_KEY=$(field AWS_SECRET_ACCESS_KEY)
SESSION_TOKEN=$(field AWS_SESSION_TOKEN)
REAL_EXPIRATION=$(field AWS_CREDENTIAL_EXPIRATION)

# Names only, never values.
[ -n "$ACCESS_KEY_ID" ] || die "AWS_ACCESS_KEY_ID missing or empty in $ENV_FILE"
[ -n "$SECRET_ACCESS_KEY" ] || die "AWS_SECRET_ACCESS_KEY missing or empty in $ENV_FILE"
[ -n "$SESSION_TOKEN" ] || die "AWS_SESSION_TOKEN missing or empty in $ENV_FILE"

CAP_EPOCH=$(($(date -u +%s) + CAP_SECONDS))
EXPIRY_EPOCH=$CAP_EPOCH
if [ -n "$REAL_EXPIRATION" ]; then
  # Honour a nearer real expiry; never let it push the re-read further out.
  if REAL_EPOCH=$(date -u -d "$REAL_EXPIRATION" +%s 2>/dev/null) &&
    [ "$REAL_EPOCH" -lt "$CAP_EPOCH" ]; then
    EXPIRY_EPOCH=$REAL_EPOCH
  fi
fi
EXPIRATION=$(date -u -d "@$EXPIRY_EPOCH" +%Y-%m-%dT%H:%M:%SZ)

printf '{"Version":1,"AccessKeyId":"%s","SecretAccessKey":"%s","SessionToken":"%s","Expiration":"%s"}\n' \
  "$(json_escape "$ACCESS_KEY_ID")" \
  "$(json_escape "$SECRET_ACCESS_KEY")" \
  "$(json_escape "$SESSION_TOKEN")" \
  "$EXPIRATION"
