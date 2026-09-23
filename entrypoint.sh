#!/bin/sh
# Credentials are resolved by botocore through the profile in scripts/aws-config,
# whose credential_process re-reads the mounted credentials file while the process
# runs. So there is nothing to source at startup and nothing to poll or restart:
# this file exists only to pass the config path and port.
#
# Do not source the credentials file here. Exported AWS_ACCESS_KEY_ID /
# AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN outrank the profile in botocore's
# resolution order, so they would shadow the shim and pin the process to whatever
# was on disk at startup -- the behaviour this replaced.
set -eu

exec litellm --config /app/config.yaml --port 4000
