#!/usr/bin/env bash
# entrypoint.sh - GitHub Actions Self-Hosted Runner container entrypoint
# Consumes single-use registration token, zeroes out token file immediately,
# configures runner on first run (or reuses existing credentials on restart), and starts it.

set -euo pipefail

REPO_FULL="${REPO_FULL:-}"
RUNNER_NAME="${RUNNER_NAME:-}"
RUNNER_LABELS="${RUNNER_LABELS:-fh-runner}"
REG_TOKEN_FILE="${REG_TOKEN_FILE:-/run/secrets/gh_runner_reg_token}"

if [ -z "$REPO_FULL" ]; then
  echo "Error: REPO_FULL environment variable is required (e.g. 'owner/repo')." >&2
  exit 1
fi

if [ -z "$RUNNER_NAME" ]; then
  echo "Error: RUNNER_NAME environment variable is required." >&2
  exit 1
fi

cd /runner

# Check whether runner has already been configured (.runner and .credentials exist)
if [ ! -f .runner ] || [ ! -f .credentials ]; then
  if [ ! -f "$REG_TOKEN_FILE" ] || [ ! -s "$REG_TOKEN_FILE" ] || [ ! -r "$REG_TOKEN_FILE" ]; then
    echo "Error: Registration token file is missing, empty, or unreadable: $REG_TOKEN_FILE" >&2
    exit 1
  fi

  # Read single-use registration token
  REG_TOKEN="$(cat "$REG_TOKEN_FILE")"

  # Zero out and remove the token file immediately to protect credentials from workflow steps
  : > "$REG_TOKEN_FILE" 2>/dev/null || rm -f "$REG_TOKEN_FILE" 2>/dev/null || true

  echo "==> Configuring GitHub Actions runner for ${REPO_FULL}..."
  ./config.sh \
    --unattended \
    --url "https://github.com/${REPO_FULL}" \
    --token "${REG_TOKEN}" \
    --name "${RUNNER_NAME}" \
    --labels "${RUNNER_LABELS}" \
    --work "/work" \
    --replace >/dev/null

  unset REG_TOKEN
else
  echo "==> Existing runner credentials found (.runner and .credentials). Skipping configuration."
  # Still ensure any passed token file is zeroed out
  : > "$REG_TOKEN_FILE" 2>/dev/null || rm -f "$REG_TOKEN_FILE" 2>/dev/null || true
fi

unset REG_TOKEN_FILE

echo "==> Starting GitHub Actions runner process..."
exec env -u REG_TOKEN -u REG_TOKEN_FILE -u PAT -u TOKEN_FILE ./run.sh
