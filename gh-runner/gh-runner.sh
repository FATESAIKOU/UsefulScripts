#!/usr/bin/env bash
# gh-runner.sh - Manage GitHub Actions Self-Hosted Runner containers
# Strictly for private repositories. Host-isolated and credential-safe.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
IMAGE_NAME="${GH_RUNNER_IMAGE:-mlp-gh-runner:latest}"
DEFAULT_REPOS="MyPMO MyBrain MyAiEntry"
DEFAULT_OWNER="FATESAIKOU"
DEFAULT_LABELS="fh-runner"

usage() {
  cat << 'EOF'
Usage:
  gh-runner.sh up [--build] [repo...]
      Start runner container(s) for specified repository/repositories.
      If --build is passed, rebuilds the runner Docker image first.
      If no repo specified, defaults to $GH_RUNNER_REPOS ("MyPMO MyBrain MyAiEntry").
  gh-runner.sh down [repo...]
      Stop and remove runner container(s) for specified repository/repositories.
  gh-runner.sh status [repo...]
      Show status of gh-runner container(s).
  gh-runner.sh build
      Build the runner Docker image.
  gh-runner.sh help | -h | --help
      Display this help message.

Environment Variables:
  GH_RUNNER_TOKEN_FILE   Path to PAT file (default: ~/.config/gh-runner/token)
  GH_RUNNER_REPOS        Default repositories (default: "MyPMO MyBrain MyAiEntry")
  GH_RUNNER_OWNER        Default owner/organization (default: "FATESAIKOU")
  GH_RUNNER_LABELS       Runner labels (default: "fh-runner")
  GH_RUNNER_IMAGE        Runner image tag (default: "mlp-gh-runner:latest")
  GH_RUNNER_HOST         Host tag in runner name (default: hostname -s)
EOF
}

get_abs_path() {
  local target="$1"
  if [[ "$target" = /* ]]; then
    printf '%s\n' "$target"
  else
    printf '%s/%s\n' "$(cd "$(dirname "$target")" && pwd -P)" "$(basename "$target")"
  fi
}

get_file_perm() {
  local f="$1"
  stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f" 2>/dev/null || true
}

validate_token_file() {
  local tf="$1"
  if [[ "$tf" == *"LLMGateway"* ]]; then
    echo "Security error: Token file path cannot contain 'LLMGateway': $tf" >&2
    exit 1
  fi

  if [ ! -f "$tf" ] || [ ! -s "$tf" ] || [ ! -r "$tf" ]; then
    echo "Error: Token file does not exist, is empty, or is unreadable: $tf" >&2
    exit 1
  fi

  local abs_tf
  abs_tf="$(get_abs_path "$tf")"
  if [[ "$abs_tf" == *"LLMGateway"* ]]; then
    echo "Security error: Resolved token file path cannot contain 'LLMGateway': $abs_tf" >&2
    exit 1
  fi

  local perm
  perm="$(get_file_perm "$abs_tf")"
  if [[ ! "$perm" =~ ^[0-7]{3,4}$ ]] || [ $(( 8#${perm} & 8#077 )) -ne 0 ]; then
    echo "Security error: Token file '$abs_tf' has overly permissive or invalid permissions (${perm:-unknown})." >&2
    echo "Group and other permissions must be 0 to protect credentials." >&2
    echo "Please execute: chmod 600 $abs_tf" >&2
    exit 1
  fi

  printf '%s\n' "$abs_tf"
}

parse_repo() {
  local raw="$1"
  local owner
  local repo_short
  if [[ "$raw" == *"/"* ]]; then
    owner="${raw%%/*}"
    repo_short="${raw#*/}"
  else
    owner="${GH_RUNNER_OWNER:-$DEFAULT_OWNER}"
    repo_short="$raw"
  fi
  printf '%s %s\n' "$owner" "$repo_short"
}

check_repo_private() {
  local owner="$1"
  local repo_short="$2"
  local token_file="$3"

  local vis
  vis=$(GH_TOKEN="$(cat "$token_file")" gh repo view "${owner}/${repo_short}" --json isPrivate,visibility --jq '"\(.isPrivate):\(.visibility)"' 2>/dev/null || true)

  local vis_lower
  vis_lower=$(printf '%s' "$vis" | tr '[:upper:]' '[:lower:]')

  if [ "$vis_lower" != "true:private" ]; then
    echo "Security error: Refusing to start runner for '${owner}/${repo_short}'." >&2
    echo "Visibility check returned: '${vis}'." >&2
    echo "Policy constraint: Only strictly private repositories (true:private) are permitted." >&2
    return 1
  fi
  return 0
}

cmd_build() {
  local host_uid
  host_uid="$(id -u)"
  echo "Building runner Docker image: ${IMAGE_NAME} (RUNNER_UID=${host_uid})..."
  docker build --build-arg "RUNNER_UID=${host_uid}" -t "${IMAGE_NAME}" "${SCRIPT_DIR}"
}

cmd_up() {
  local force_build=false
  if [ $# -gt 0 ] && [ "$1" = "--build" ]; then
    force_build=true
    shift
  fi

  local raw_repos=("$@")
  if [ ${#raw_repos[@]} -eq 0 ]; then
    # Read from env GH_RUNNER_REPOS or default
    read -r -a raw_repos <<< "${GH_RUNNER_REPOS:-$DEFAULT_REPOS}"
  fi

  local token_file_setting="${GH_RUNNER_TOKEN_FILE:-$HOME/.config/gh-runner/token}"
  local abs_token_file
  abs_token_file="$(validate_token_file "$token_file_setting")"

  if [ "$force_build" = true ] || ! docker image inspect "${IMAGE_NAME}" >/dev/null 2>&1; then
    cmd_build
  fi

  local host_tag
  host_tag="${GH_RUNNER_HOST:-$(hostname -s)}"
  local runner_labels="${GH_RUNNER_LABELS:-$DEFAULT_LABELS}"

  for raw in "${raw_repos[@]}"; do
    local parsed
    parsed="$(parse_repo "$raw")"
    local owner="${parsed%% *}"
    local repo_short="${parsed#* }"

    echo "==> Verifying repository visibility for ${owner}/${repo_short}..."
    if ! check_repo_private "$owner" "$repo_short" "$abs_token_file"; then
      exit 1
    fi

    echo "==> Fetching single-use runner registration token for ${owner}/${repo_short}..."
    local pat
    pat="$(cat "$abs_token_file")"
    local reg_json
    reg_json=$(printf 'header = "Authorization: Bearer %s"\nheader = "Accept: application/vnd.github+json"\n' "$pat" | \
      curl --silent --show-error --fail --request POST --config - \
        "https://api.github.com/repos/${owner}/${repo_short}/actions/runners/registration-token" 2>/dev/null || true)
    unset pat

    local reg_token
    reg_token=$(printf '%s' "$reg_json" | jq -r '.token // empty' 2>/dev/null || true)
    unset reg_json

    if [ -z "$reg_token" ] || [ "$reg_token" = "null" ]; then
      echo "Error: Failed to obtain registration token from GitHub API for ${owner}/${repo_short}." >&2
      exit 1
    fi

    local state_dir="${GH_RUNNER_STATE_DIR:-${TMPDIR:-/tmp}/gh-runner-state}"
    mkdir -p "$state_dir"
    chmod 0700 "$state_dir"
    local reg_token_file="${state_dir}/reg-${repo_short}.token"
    printf '%s\n' "$reg_token" > "$reg_token_file"
    chmod 0600 "$reg_token_file"
    unset reg_token

    local container_name="gh-runner-${repo_short}"
    local runner_name="mlp-${host_tag}-${repo_short}"

    echo "==> Preparing container ${container_name}..."
    docker rm -f "${container_name}" >/dev/null 2>&1 || true

    echo "==> Starting container ${container_name} for ${owner}/${repo_short}..."
    docker run -d \
      --name "${container_name}" \
      --restart unless-stopped \
      --cap-drop ALL \
      --security-opt no-new-privileges:true \
      -v "${reg_token_file}:/run/secrets/gh_runner_reg_token" \
      -v "gh-runner-work-${repo_short}:/work" \
      -e REPO_FULL="${owner}/${repo_short}" \
      -e RUNNER_NAME="${runner_name}" \
      -e RUNNER_LABELS="${runner_labels}" \
      -e REG_TOKEN_FILE="/run/secrets/gh_runner_reg_token" \
      "${IMAGE_NAME}"
    echo "==> Successfully launched ${container_name}."
  done
}

cmd_down() {
  local raw_repos=("$@")
  if [ ${#raw_repos[@]} -eq 0 ]; then
    read -r -a raw_repos <<< "${GH_RUNNER_REPOS:-$DEFAULT_REPOS}"
  fi

  for raw in "${raw_repos[@]}"; do
    local parsed
    parsed="$(parse_repo "$raw")"
    local repo_short="${parsed#* }"
    local container_name="gh-runner-${repo_short}"
    echo "==> Stopping and removing container ${container_name}..."
    docker rm -f "${container_name}" >/dev/null 2>&1 || true
    echo "==> Removed ${container_name}."
  done
}

cmd_status() {
  echo "==> Listing gh-runner containers:"
  docker ps -a --filter "name=^/gh-runner-"
}

main() {
  if [ $# -eq 0 ]; then
    usage
    exit 0
  fi

  local action="$1"
  shift

  case "$action" in
    up)
      cmd_up "$@"
      ;;
    down)
      cmd_down "$@"
      ;;
    status)
      cmd_status "$@"
      ;;
    build)
      cmd_build
      ;;
    help|--help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Error: Unknown action '$action'" >&2
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
