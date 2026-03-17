#!/bin/sh

ENV_FILE="/app/env.aws"
RELOAD_INTERVAL="${ENV_RELOAD_INTERVAL:-300}"
RELOAD_FLAG="/tmp/reload_env"
OUTPUT_PIPE="/tmp/litellm_output"
# Cooldown in seconds to avoid rapid reload loops
RELOAD_COOLDOWN="${ENV_RELOAD_COOLDOWN:-30}"
LAST_RELOAD_TIME=0

load_env() {
  if [ -f "$ENV_FILE" ]; then
    set -a
    . "$ENV_FILE"
    set +a
    echo "[entrypoint] Loaded env from $ENV_FILE"
  fi
}

start_litellm() {
  load_env

  # Create named pipe for output monitoring
  rm -f "$OUTPUT_PIPE"
  mkfifo "$OUTPUT_PIPE"

  # Background monitor: reads litellm output, prints to stdout,
  # and flags reload when expired token errors are detected
  (while IFS= read -r line; do
    printf '%s\n' "$line"
    case "$line" in
      *"security token included in the request is expired"*|*"security token"*"is expired"*|*"The security token"*"expired"*)
        if [ ! -f "$RELOAD_FLAG" ]; then
          touch "$RELOAD_FLAG"
          echo "[entrypoint] Detected expired AWS security token in logs"
        fi
        ;;
    esac
  done < "$OUTPUT_PIPE") &
  MONITOR_PID=$!

  # Start litellm with output redirected to the pipe
  litellm --config /app/config.yaml --port 4000 > "$OUTPUT_PIPE" 2>&1 &
  LITELLM_PID=$!
  echo "[entrypoint] Started litellm (PID $LITELLM_PID)"
}

stop_litellm() {
  if [ -n "$LITELLM_PID" ] && kill -0 "$LITELLM_PID" 2>/dev/null; then
    echo "[entrypoint] Stopping litellm (PID $LITELLM_PID)"
    kill "$LITELLM_PID"
    wait "$LITELLM_PID" 2>/dev/null
  fi
  # Clean up monitor process
  if [ -n "$MONITOR_PID" ] && kill -0 "$MONITOR_PID" 2>/dev/null; then
    kill "$MONITOR_PID" 2>/dev/null
    wait "$MONITOR_PID" 2>/dev/null
  fi
  rm -f "$OUTPUT_PIPE"
}

reload_litellm() {
  CURRENT_TIME=$(date +%s)
  ELAPSED=$((CURRENT_TIME - LAST_RELOAD_TIME))
  if [ "$ELAPSED" -lt "$RELOAD_COOLDOWN" ]; then
    echo "[entrypoint] Skipping reload, cooldown active (${ELAPSED}s < ${RELOAD_COOLDOWN}s)"
    rm -f "$RELOAD_FLAG"
    return
  fi

  echo "[entrypoint] Reloading litellm with fresh env..."
  stop_litellm
  start_litellm
  LAST_RELOAD_TIME=$(date +%s)
  rm -f "$RELOAD_FLAG"

  # Update checksum after reload
  if [ -f "$ENV_FILE" ]; then
    LAST_CHECKSUM=$(md5sum "$ENV_FILE" 2>/dev/null || md5 "$ENV_FILE" 2>/dev/null)
  fi
}

# Handle container shutdown
trap 'stop_litellm; exit 0' TERM INT

start_litellm
LAST_RELOAD_TIME=$(date +%s)

# Store initial checksum
LAST_CHECKSUM=""
if [ -f "$ENV_FILE" ]; then
  LAST_CHECKSUM=$(md5sum "$ENV_FILE" 2>/dev/null || md5 "$ENV_FILE" 2>/dev/null)
fi

# Main loop: check for reload triggers every few seconds
while true; do
  sleep 5

  # Check if litellm is still running
  if ! kill -0 "$LITELLM_PID" 2>/dev/null; then
    echo "[entrypoint] litellm exited unexpectedly, restarting..."
    start_litellm
    LAST_RELOAD_TIME=$(date +%s)
    continue
  fi

  # Check if expired token was detected in logs
  if [ -f "$RELOAD_FLAG" ]; then
    echo "[entrypoint] Expired token detected, triggering reload..."
    reload_litellm
    continue
  fi

  # Periodically check if env file changed (every RELOAD_INTERVAL seconds)
  CURRENT_TIME=$(date +%s)
  ELAPSED=$((CURRENT_TIME - LAST_RELOAD_TIME))
  if [ "$ELAPSED" -ge "$RELOAD_INTERVAL" ] && [ -f "$ENV_FILE" ]; then
    CURRENT_CHECKSUM=$(md5sum "$ENV_FILE" 2>/dev/null || md5 "$ENV_FILE" 2>/dev/null)
    if [ "$CURRENT_CHECKSUM" != "$LAST_CHECKSUM" ]; then
      echo "[entrypoint] Detected env file change, reloading..."
      reload_litellm
    fi
  fi
done
