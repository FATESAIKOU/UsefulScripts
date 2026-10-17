#!/usr/bin/env bash
# test_gh_runner.sh - Comprehensive offline mock test suite for gh-runner
# Strictly offline: uses mocked gh, docker, and curl binaries.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
GH_RUNNER_DIR="$(cd "${TEST_DIR}/.." && pwd -P)"
GH_RUNNER_SCRIPT="${GH_RUNNER_DIR}/gh-runner.sh"
ENTRYPOINT_SCRIPT="${GH_RUNNER_DIR}/entrypoint.sh"
DOCKERFILE="${GH_RUNNER_DIR}/Dockerfile"

MOCK_TMP="$(mktemp -d /tmp/gh-runner-test.XXXXXX)"
trap 'rm -rf "${MOCK_TMP}"' EXIT

MOCK_BIN="${MOCK_TMP}/bin"
mkdir -p "${MOCK_BIN}"

PASSED_COUNT=0
FAILED_COUNT=0

pass() {
  echo "[PASS] $1"
  PASSED_COUNT=$((PASSED_COUNT + 1))
}

fail() {
  echo "[FAIL] $1" >&2
  FAILED_COUNT=$((FAILED_COUNT + 1))
}

# --- Setup Mocks ---

# Mock docker
cat << 'EOF' > "${MOCK_BIN}/docker"
#!/usr/bin/env bash
echo "docker $@" >> "${MOCK_TMP}/docker_calls.log"
subcmd="${1:-}"
case "$subcmd" in
  image)
    if [ "${2:-}" = "inspect" ]; then
      if [ "${DOCKER_INSPECT_FAIL:-0}" = "1" ]; then
        exit 1
      fi
      exit 0
    fi
    exit 0
    ;;
  build)
    echo "Mock docker build succeeded"
    exit 0
    ;;
  rm)
    echo "Mock docker rm: $@"
    exit 0
    ;;
  run)
    echo "$@" >> "${MOCK_TMP}/docker_run_calls.log"
    echo "mock_container_id_12345"
    exit 0
    ;;
  ps)
    echo "CONTAINER ID   IMAGE                  COMMAND           CREATED        STATUS        PORTS     NAMES"
    echo "1234567890ab   mlp-gh-runner:latest   \"/entrypoint.sh\" 2 hours ago    Up 2 hours              gh-runner-MyPMO"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
chmod 0755 "${MOCK_BIN}/docker"

# Mock gh
cat << 'EOF' > "${MOCK_BIN}/gh"
#!/usr/bin/env bash
echo "$@" >> "${MOCK_TMP}/gh_calls.log"
mode="${GH_MOCK_MODE:-private}"
case "$mode" in
  public)
    printf "false:PUBLIC\n"
    exit 0
    ;;
  fail)
    echo "gh: repository not found" >&2
    exit 1
    ;;
  empty)
    exit 0
    ;;
  private|*)
    printf "true:PRIVATE\n"
    exit 0
    ;;
esac
EOF
chmod 0755 "${MOCK_BIN}/gh"

# Mock curl (handles GitHub API registration token exchange via stdin config)
cat << 'EOF' > "${MOCK_BIN}/curl"
#!/usr/bin/env bash
echo "$@" >> "${MOCK_TMP}/curl_cli_args.log"

has_config_stdin=false
for arg in "$@"; do
  if [ "$arg" = "--config" ]; then
    has_config_stdin=true
  fi
done

if [ "$has_config_stdin" = true ]; then
  cat >> "${MOCK_TMP}/curl_stdin.log"
  # Validate that Authorization header was passed via stdin
  if grep -q "Authorization: Bearer" "${MOCK_TMP}/curl_stdin.log"; then
    printf '{"token": "FAKE_REG_TOKEN_ABC123XYZ", "expires_at": "2026-10-17T12:00:00Z"}\n'
    exit 0
  fi
fi

echo "Curl mock failed to find valid config" >&2
exit 1
EOF
chmod 0755 "${MOCK_BIN}/curl"

# Put mock bin ahead of PATH
export PATH="${MOCK_BIN}:${PATH}"
export MOCK_TMP

echo "=========================================================="
echo " Starting gh-runner Offline Mock Test Suite"
echo " Working directory: ${GH_RUNNER_DIR}"
echo " Temporary mock root: ${MOCK_TMP}"
echo "=========================================================="

# Create fake token file
FAKE_TOKEN_FILE="${MOCK_TMP}/fake_token"
echo "ghp_MOCK_SECRET_PAT_TOKEN_12345" > "${FAKE_TOKEN_FILE}"
chmod 0600 "${FAKE_TOKEN_FILE}"

# -----------------------------------------------------------------
# T1: Public Repo Rejection
# -----------------------------------------------------------------
echo ""
echo "--- Running T1: Public Repo Rejection ---"
rm -f "${MOCK_TMP}/docker_calls.log" "${MOCK_TMP}/docker_run_calls.log" "${MOCK_TMP}/gh_calls.log"

set +e
t1_out=$(GH_RUNNER_TOKEN_FILE="${FAKE_TOKEN_FILE}" \
         GH_MOCK_MODE="public" \
         "${GH_RUNNER_SCRIPT}" up MyLinuxPool 2>&1)
t1_exit=$?
set -e

if [ $t1_exit -ne 0 ]; then
  if [ ! -f "${MOCK_TMP}/docker_run_calls.log" ]; then
    if echo "${t1_out}" | grep -q "Only strictly private repositories"; then
      pass "T1: Public repo rejected with non-zero exit code ($t1_exit), error reported, and docker run never executed."
    else
      fail "T1: Public repo rejected but expected error message not found in output: ${t1_out}"
    fi
  else
    fail "T1: docker run was unexpectedly executed for public repo!"
  fi
else
  fail "T1: Expected non-zero exit code for public repo, got 0"
fi

# -----------------------------------------------------------------
# T2: Query Failure Rejection
# -----------------------------------------------------------------
echo ""
echo "--- Running T2: Query Failure Rejection ---"
rm -f "${MOCK_TMP}/docker_calls.log" "${MOCK_TMP}/docker_run_calls.log" "${MOCK_TMP}/gh_calls.log"

set +e
t2_out=$(GH_RUNNER_TOKEN_FILE="${FAKE_TOKEN_FILE}" \
         GH_MOCK_MODE="fail" \
         "${GH_RUNNER_SCRIPT}" up MyPMO 2>&1)
t2_exit=$?
set -e

if [ $t2_exit -ne 0 ]; then
  if [ ! -f "${MOCK_TMP}/docker_run_calls.log" ]; then
    pass "T2: Query failure resulted in non-zero exit ($t2_exit) and docker run was not executed."
  else
    fail "T2: docker run was called despite query failure!"
  fi
else
  fail "T2: Query failure unexpectedly exited with 0"
fi

# Also test empty query response
rm -f "${MOCK_TMP}/docker_calls.log" "${MOCK_TMP}/docker_run_calls.log" "${MOCK_TMP}/gh_calls.log"
set +e
t2b_out=$(GH_RUNNER_TOKEN_FILE="${FAKE_TOKEN_FILE}" \
          GH_MOCK_MODE="empty" \
          "${GH_RUNNER_SCRIPT}" up MyPMO 2>&1)
t2b_exit=$?
set -e
if [ $t2b_exit -ne 0 ]; then
  if [ ! -f "${MOCK_TMP}/docker_run_calls.log" ]; then
    pass "T2: Empty query response resulted in non-zero exit ($t2b_exit) and docker run was not executed."
  else
    fail "T2: Empty query response triggered docker run unexpectedly!"
  fi
else
  fail "T2: Empty query response unexpectedly exited with 0"
fi

# -----------------------------------------------------------------
# T3: Private Repo Normal Startup & Isolation Parameters Check (High 1 Check)
# -----------------------------------------------------------------
echo ""
echo "--- Running T3: Private Repo Normal Startup & Isolation Parameters Check ---"
rm -f "${MOCK_TMP}/docker_calls.log" "${MOCK_TMP}/docker_run_calls.log" "${MOCK_TMP}/gh_calls.log" "${MOCK_TMP}/curl_cli_args.log" "${MOCK_TMP}/curl_stdin.log"

set +e
t3_out=$(GH_RUNNER_TOKEN_FILE="${FAKE_TOKEN_FILE}" \
         GH_MOCK_MODE="private" \
         "${GH_RUNNER_SCRIPT}" up MyPMO 2>&1)
t3_exit=$?
set -e

if [ $t3_exit -eq 0 ]; then
  if [ -f "${MOCK_TMP}/docker_run_calls.log" ]; then
    docker_run_cmd=$(cat "${MOCK_TMP}/docker_run_calls.log")

    t3_checks_passed=true

    # 1. Must NOT contain /var/run/docker.sock
    if echo "${docker_run_cmd}" | grep -q "docker\.sock"; then
      fail "T3: docker run command contains /var/run/docker.sock!"
      t3_checks_passed=false
    fi

    # 2. Must NOT contain --privileged
    if echo "${docker_run_cmd}" | grep -q -- "--privileged"; then
      fail "T3: docker run command contains --privileged!"
      t3_checks_passed=false
    fi

    # 3. Must NOT contain long-lived PAT plaintext
    if echo "${docker_run_cmd}" | grep -q "ghp_MOCK_SECRET_PAT_TOKEN_12345"; then
      fail "T3: Plaintext long-lived PAT leaked into docker run arguments!"
      t3_checks_passed=false
    fi

    # 4. Must NOT contain single-use reg_token plaintext on command line
    if echo "${docker_run_cmd}" | grep -q "FAKE_REG_TOKEN_ABC123XYZ"; then
      fail "T3: Single-use registration token leaked into docker run arguments!"
      t3_checks_passed=false
    fi

    # 5. Must NOT mount long-lived PAT file
    if echo "${docker_run_cmd}" | grep -q "${FAKE_TOKEN_FILE}"; then
      fail "T3: Long-lived PAT file was mounted into container!"
      t3_checks_passed=false
    fi

    # 6. Must contain single-use reg_token mount
    if ! echo "${docker_run_cmd}" | grep -q "/run/secrets/gh_runner_reg_token"; then
      fail "T3: Single-use reg_token mount '/run/secrets/gh_runner_reg_token' missing in docker run args!"
      t3_checks_passed=false
    fi

    # 7. Must contain RUNNER_LABELS=fh-runner
    if ! echo "${docker_run_cmd}" | grep -q "RUNNER_LABELS=fh-runner"; then
      fail "T3: RUNNER_LABELS=fh-runner missing in docker run args!"
      t3_checks_passed=false
    fi

    # 8. Must contain --cap-drop ALL and --security-opt no-new-privileges:true
    if ! echo "${docker_run_cmd}" | grep -q -- "--cap-drop ALL" || ! echo "${docker_run_cmd}" | grep -q "no-new-privileges:true"; then
      fail "T3: Security flags --cap-drop ALL or no-new-privileges:true missing!"
      t3_checks_passed=false
    fi

    # 9. Must contain named volume for work
    if ! echo "${docker_run_cmd}" | grep -q "gh-runner-work-MyPMO:/work"; then
      fail "T3: Named volume gh-runner-work-MyPMO:/work missing!"
      t3_checks_passed=false
    fi

    # 10. Verify curl CLI args on host do NOT contain plaintext PAT
    if [ -f "${MOCK_TMP}/curl_cli_args.log" ] && grep -q "ghp_MOCK_SECRET_PAT_TOKEN_12345" "${MOCK_TMP}/curl_cli_args.log"; then
      fail "T3: curl CLI arguments on host contained plaintext PAT!"
      t3_checks_passed=false
    fi

    if [ "$t3_checks_passed" = true ]; then
      pass "T3: Private repo startup succeeded with strict isolation parameters verified (long-lived PAT not mounted, no token on CLI, single-use token mounted, security opts)."
    fi
  else
    fail "T3: docker run was not found in log"
  fi
else
  fail "T3: Private repo startup failed with code $t3_exit: $t3_out"
fi

# -----------------------------------------------------------------
# T4: LLMGateway Path Protection
# -----------------------------------------------------------------
echo ""
echo "--- Running T4: LLMGateway Path Protection ---"
rm -f "${MOCK_TMP}/docker_calls.log" "${MOCK_TMP}/docker_run_calls.log"

LLM_DIR="${MOCK_TMP}/LLMGateway-secret"
mkdir -p "${LLM_DIR}"
LLM_TOKEN_FILE="${LLM_DIR}/token"
echo "some_token" > "${LLM_TOKEN_FILE}"

set +e
t4_out=$(GH_RUNNER_TOKEN_FILE="${LLM_TOKEN_FILE}" \
         "${GH_RUNNER_SCRIPT}" up MyPMO 2>&1)
t4_exit=$?
set -e

if [ $t4_exit -ne 0 ]; then
  if echo "${t4_out}" | grep -q "LLMGateway"; then
    if [ ! -f "${MOCK_TMP}/docker_run_calls.log" ]; then
      pass "T4: LLMGateway path detected and rejected before starting docker container."
    else
      fail "T4: docker run was executed despite LLMGateway in token path!"
    fi
  else
    fail "T4: Non-zero exit code received but error did not mention LLMGateway: $t4_out"
  fi
else
  fail "T4: LLMGateway token path unexpectedly passed with code 0"
fi

# -----------------------------------------------------------------
# T5: entrypoint.sh Registration & Token Wipe Check (High 1 & Restart)
# -----------------------------------------------------------------
echo ""
echo "--- Running T5: entrypoint.sh Registration & Token Wipe Check ---"

RUNNER_MOCK_DIR="${MOCK_TMP}/runner"
mkdir -p "${RUNNER_MOCK_DIR}"

# Fake config.sh in mock runner dir
cat << 'EOF' > "${RUNNER_MOCK_DIR}/config.sh"
#!/usr/bin/env bash
echo "$@" >> "${MOCK_TMP}/config_args.log"
exit 0
EOF
chmod 0755 "${RUNNER_MOCK_DIR}/config.sh"

# Fake run.sh in mock runner dir
cat << 'EOF' > "${RUNNER_MOCK_DIR}/run.sh"
#!/usr/bin/env bash
echo "$@" >> "${MOCK_TMP}/run_args.log"
env > "${MOCK_TMP}/run_env.log"
echo "Mock actions runner running..."
exit 0
EOF
chmod 0755 "${RUNNER_MOCK_DIR}/run.sh"

# Create fake single-use reg_token file
TEST_REG_TOKEN="FAKE_REG_TOKEN_ABC123XYZ"
TEST_REG_TOKEN_FILE="${MOCK_TMP}/test_reg_token_file"
echo "${TEST_REG_TOKEN}" > "${TEST_REG_TOKEN_FILE}"
chmod 0600 "${TEST_REG_TOKEN_FILE}"

rm -f "${MOCK_TMP}/config_args.log" "${MOCK_TMP}/run_env.log" "${RUNNER_MOCK_DIR}/.runner" "${RUNNER_MOCK_DIR}/.credentials"

set +e
if [ ! -d "/runner" ]; then
  SED_ENTRYPOINT="${MOCK_TMP}/entrypoint_tested.sh"
  sed "s|cd /runner|cd ${RUNNER_MOCK_DIR}|g" "${ENTRYPOINT_SCRIPT}" > "${SED_ENTRYPOINT}"
  chmod 0755 "${SED_ENTRYPOINT}"
  RUN_SCRIPT_TARGET="${SED_ENTRYPOINT}"
else
  RUN_SCRIPT_TARGET="${ENTRYPOINT_SCRIPT}"
fi

entry_output=$(REPO_FULL="FATESAIKOU/MyPMO" \
               RUNNER_NAME="mlp-testnode-MyPMO" \
               RUNNER_LABELS="fh-runner" \
               REG_TOKEN_FILE="${TEST_REG_TOKEN_FILE}" \
               "${RUN_SCRIPT_TARGET}" 2>&1)
entry_exit=$?
set -e

if [ $entry_exit -eq 0 ]; then
  t5_passed=true

  # 1. Verify config.sh received proper arguments
  config_log="$(cat "${MOCK_TMP}/config_args.log")"
  if ! echo "${config_log}" | grep -q -- "--labels fh-runner" || \
     ! echo "${config_log}" | grep -q -- "--url https://github.com/FATESAIKOU/MyPMO" || \
     ! echo "${config_log}" | grep -q -- "--token FAKE_REG_TOKEN_ABC123XYZ"; then
    fail "T5: config.sh arguments were incomplete: ${config_log}"
    t5_passed=false
  fi

  # 2. Verify run.sh environment does NOT contain PAT or REG_TOKEN or REG_TOKEN_FILE
  run_env="$(cat "${MOCK_TMP}/run_env.log")"
  if echo "${run_env}" | grep -E -q "(FAKE_REG_TOKEN_ABC123XYZ|PAT=|REG_TOKEN=|REG_TOKEN_FILE=|TOKEN_FILE=)"; then
    fail "T5: Sensitive credentials found in run.sh environment variables!"
    t5_passed=false
  fi

  # 3. Verify entrypoint output did NOT leak REG_TOKEN
  if echo "${entry_output}" | grep -E -q "FAKE_REG_TOKEN_ABC123XYZ"; then
    fail "T5: Sensitive credentials leaked into stdout/stderr of entrypoint!"
    t5_passed=false
  fi

  # 4. CRITICAL: Verify that the REG_TOKEN_FILE was zeroed out (0 bytes)
  if [ -s "${TEST_REG_TOKEN_FILE}" ]; then
    fail "T5: REG_TOKEN_FILE was not emptied! Content length > 0 bytes."
    t5_passed=false
  else
    echo "  - REG_TOKEN_FILE was verified to be 0 bytes after registration."
  fi

  # 5. Verify container restart behavior (existing .runner and .credentials skips config.sh)
  touch "${RUNNER_MOCK_DIR}/.runner" "${RUNNER_MOCK_DIR}/.credentials"
  echo "ANOTHER_TEST_TOKEN" > "${TEST_REG_TOKEN_FILE}"
  rm -f "${MOCK_TMP}/config_args.log"

  restart_output=$(REPO_FULL="FATESAIKOU/MyPMO" \
                  RUNNER_NAME="mlp-testnode-MyPMO" \
                  RUNNER_LABELS="fh-runner" \
                  REG_TOKEN_FILE="${TEST_REG_TOKEN_FILE}" \
                  "${RUN_SCRIPT_TARGET}" 2>&1)
  restart_exit=$?

  if [ $restart_exit -eq 0 ]; then
    if [ -f "${MOCK_TMP}/config_args.log" ]; then
      fail "T5: config.sh was unexpectedly called during container restart when .runner/.credentials existed!"
      t5_passed=false
    else
      echo "  - Existing credentials correctly detected; ./config.sh was skipped on restart."
    fi
    if [ -s "${TEST_REG_TOKEN_FILE}" ]; then
      fail "T5: REG_TOKEN_FILE was not emptied on restart!"
      t5_passed=false
    fi
  else
    fail "T5: Restart test failed with exit code $restart_exit: $restart_output"
    t5_passed=false
  fi

  if [ "$t5_passed" = true ]; then
    pass "T5: entrypoint consumed token, wiped token file to 0 bytes, cleaned env, and handled container restart cleanly."
  fi
else
  fail "T5: entrypoint execution failed with code $entry_exit: $entry_output"
fi

# -----------------------------------------------------------------
# T6: Static Checks (bash -n, set -x audit, Dockerfile inspection)
# -----------------------------------------------------------------
echo ""
echo "--- Running T6: Static Checks ---"
t6_passed=true

# Check bash syntax
if bash -n "${GH_RUNNER_SCRIPT}" && bash -n "${ENTRYPOINT_SCRIPT}" && bash -n "${BASH_SOURCE[0]}"; then
  echo "  - bash -n syntax check passed."
else
  fail "T6: bash -n syntax check failed!"
  t6_passed=false
fi

# Audit for set -x
if grep -q "set -x" "${GH_RUNNER_SCRIPT}" "${ENTRYPOINT_SCRIPT}"; then
  fail "T6: 'set -x' detected in scripts!"
  t6_passed=false
else
  echo "  - No 'set -x' found in scripts."
fi

# Check Dockerfile components
if [ -f "${DOCKERFILE}" ]; then
  df_content="$(cat "${DOCKERFILE}")"
  if echo "${df_content}" | grep -q "python3" && \
     echo "${df_content}" | grep -q "gh" && \
     echo "${df_content}" | grep -q "node" && \
     echo "${df_content}" | grep -q "/opt/hostedtoolcache" && \
     echo "${df_content}" | grep -q "PIP_BREAK_SYSTEM_PACKAGES=1" && \
     echo "${df_content}" | grep -q "USER runner"; then
    echo "  - Dockerfile contains python3, gh, node, /opt/hostedtoolcache, PIP_BREAK_SYSTEM_PACKAGES=1, and unprivileged runner user."
  else
    fail "T6: Dockerfile is missing required components!"
    t6_passed=false
  fi
else
  fail "T6: Dockerfile not found at ${DOCKERFILE}!"
  t6_passed=false
fi

if [ "$t6_passed" = true ]; then
  pass "T6: Static syntax checks, 'set -x' audit, and Dockerfile composition verified."
fi

# -----------------------------------------------------------------
# T7: Additional Subcommand Checks (down, status, help)
# -----------------------------------------------------------------
echo ""
echo "--- Running T7: Subcommands down, status, help ---"
rm -f "${MOCK_TMP}/docker_calls.log"

set +e
help_out=$("${GH_RUNNER_SCRIPT}" --help 2>&1)
help_exit=$?
status_out=$("${GH_RUNNER_SCRIPT}" status 2>&1)
status_exit=$?
down_out=$("${GH_RUNNER_SCRIPT}" down MyPMO 2>&1)
down_exit=$?
set -e

if [ $help_exit -eq 0 ] && [ $status_exit -eq 0 ] && [ $down_exit -eq 0 ]; then
  if grep -q "rm -f gh-runner-MyPMO" "${MOCK_TMP}/docker_calls.log"; then
    pass "T7: Subcommands (help, status, down) executed successfully."
  else
    fail "T7: down command did not execute docker rm as expected!"
  fi
else
  fail "T7: One or more subcommands failed (help:$help_exit status:$status_exit down:$down_exit)"
fi

echo ""
echo "=========================================================="
echo " Test Summary: ${PASSED_COUNT} passed, ${FAILED_COUNT} failed."
echo "=========================================================="

if [ "${FAILED_COUNT}" -eq 0 ]; then
  exit 0
else
  exit 1
fi
