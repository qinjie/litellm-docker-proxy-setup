#!/bin/sh
# Credentials are resolved by botocore through the profile in scripts/aws-config,
# whose credential_process re-reads the mounted credentials file while the process
# runs. So there is nothing to source at startup and nothing to poll or restart:
# this file passes the config path and port, and reads one botocore value below.
#
# Do not source the credentials file here. Exported AWS_ACCESS_KEY_ID /
# AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN outrank the profile in botocore's
# resolution order, so they would shadow the shim and pin the process to whatever
# was on disk at startup -- the behaviour this replaced.
set -eu

# botocore's advisory refresh window, read from the botocore installed in this image
# rather than assumed, because the image tracks main-latest. The shim places
# Expiration relative to it, so a window that moved would silently move the re-read
# interval off LITELLM_CREDS_REREAD_DELAY. The credentials are built the way
# ProcessProvider builds them from credential_process output, so the value is the
# one the shim's credentials actually get. Values are fabricated; nothing is sent.
if window=$(python - 2>/dev/null <<'PY'
from botocore.credentials import RefreshableCredentials

creds = RefreshableCredentials.create_from_metadata(
    {"access_key": "x", "secret_key": "x", "token": "x", "expiry_time": "2099-01-01T00:00:00Z"},
    lambda: None,
    "custom-process",
)
window = creds._advisory_refresh_timeout
assert window == int(window) and window >= 1
print(int(window))
PY
); then
  export LITELLM_CREDS_ADVISORY_WINDOW="$window"
  echo "entrypoint: botocore advisory refresh window is ${window}s" >&2
else
  echo "entrypoint: WARNING: cannot read botocore's advisory refresh window (botocore internals changed?); the shim falls back to 900s, and scheduled re-reads may not follow LITELLM_CREDS_REREAD_DELAY" >&2
fi

exec litellm --config /app/config.yaml --port 4000
