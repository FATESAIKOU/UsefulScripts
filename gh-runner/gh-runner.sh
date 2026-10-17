#!/usr/bin/env bash
# gh-runner.sh - Manage GitHub Actions Self-Hosted Runner containers
# Strictly for private repositories. Host-isolated and credential-safe.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
IMAGE_NAME="${GH_RUNNER_IMAGE:-mlp-gh-runner:latest}"
DEFAULT_REPOS="MyPMO MyBrain MyAiEntry MyLinuxPool"
DEFAULT_OWNER="FATESAIKOU"
DEFAULT_LABELS="fh-runner"

usage() {
  cat << 'EOF'
Usage:
  gh-runner.sh up [--build] [--count N] [--cpus <cpus>] [--memory <mem>] [--repo repo...] [repo...]
      Start runner container(s) for specified repository/repositories.
      --count, -n <N>  Number of runner containers per repository (default: $GH_RUNNER_COUNT or 1).
      --cpus <cpus>    Optional CPU limit for each container (e.g. 2, 1.5).
      --memory <mem>   Optional memory limit for each container (e.g. 4g, 512m).
      If --build is passed, rebuilds the runner Docker image first.
      If no repo specified, defaults to $GH_RUNNER_REPOS ("MyPMO MyBrain MyAiEntry MyLinuxPool").
  gh-runner.sh down [--repo repo...] [repo...]
      Stop and remove runner container(s) for specified repository/repositories.
  gh-runner.sh status [--repo repo...] [repo...]
      Show status of gh-runner container(s).
  gh-runner.sh build
      Build the runner Docker image.
  gh-runner.sh help | -h | --help
      Display this help message.

Environment Variables:
  GH_RUNNER_TOKEN_FILE   Path to PAT file (default: ~/.config/gh-runner/token)
  GH_RUNNER_REPOS        Default repositories (default: "MyPMO MyBrain MyAiEntry MyLinuxPool")
  GH_RUNNER_OWNER        Default owner/organization (default: "FATESAIKOU")
  GH_RUNNER_COUNT        Number of runner containers per repo (default: 1)
  GH_RUNNER_CPUS         Optional CPU limit per container (e.g. 2, default: unlimited)
  GH_RUNNER_MEMORY       Optional memory limit per container (e.g. 4g, default: unlimited)
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
  local raw_repos=()
  local count="${GH_RUNNER_COUNT:-1}"
  local cpus="${GH_RUNNER_CPUS:-}"
  local memory="${GH_RUNNER_MEMORY:-}"

  while [ $# -gt 0 ]; do
    case "$1" in
      --build)
        force_build=true
        ;;
      --count|-n)
        shift
        if [ $# -eq 0 ]; then
          echo "Error: Missing argument for --count / -n" >&2
          exit 1
        fi
        count="$1"
        ;;
      --count=*)
        count="${1#--count=}"
        ;;
      --cpus)
        shift
        if [ $# -eq 0 ]; then
          echo "Error: Missing argument for --cpus" >&2
          exit 1
        fi
        cpus="$1"
        ;;
      --cpus=*)
        cpus="${1#--cpus=}"
        ;;
      --memory)
        shift
        if [ $# -eq 0 ]; then
          echo "Error: Missing argument for --memory" >&2
          exit 1
        fi
        memory="$1"
        ;;
      --memory=*)
        memory="${1#--memory=}"
        ;;
      --repo)
        shift
        if [ $# -gt 0 ]; then
          raw_repos+=("$1")
        fi
        ;;
      --repo=*)
        raw_repos+=("${1#--repo=}")
        ;;
      *)
        raw_repos+=("$1")
        ;;
    esac
    shift
  done

  if [[ ! "$count" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: Invalid count '$count'. Must be a positive integer." >&2
    exit 1
  fi

  if [ -n "$cpus" ]; then
    if [[ "$cpus" =~ ^- ]] || [[ "$cpus" =~ [[:space:]] ]]; then
      echo "Error: Invalid cpus value '$cpus'." >&2
      exit 1
    fi
  fi

  if [ -n "$memory" ]; then
    if [[ "$memory" =~ ^- ]] || [[ "$memory" =~ [[:space:]] ]]; then
      echo "Error: Invalid memory value '$memory'." >&2
      exit 1
    fi
  fi

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

    # Always remove legacy unnumbered container first
    docker rm -f "gh-runner-${repo_short}" >/dev/null 2>&1 || true

    # Query and remove any existing numbered containers for ${repo_short}
    local existing_containers
    existing_containers="$(docker ps -a --filter "name=^/gh-runner-${repo_short}-" --format '{{.Names}}' 2>/dev/null | grep -E "^gh-runner-${repo_short}-[0-9]+$" || true)"
    if [ -n "$existing_containers" ]; then
      while IFS= read -r old_c; do
        [ -n "$old_c" ] && docker rm -f "$old_c" >/dev/null 2>&1 || true
      done <<< "$existing_containers"
    fi

    # Clean up old token files for ${repo_short} in ${state_dir}
    rm -f "${state_dir}/reg-${repo_short}.token" "${state_dir}"/reg-"${repo_short}"-*.token 2>/dev/null || true

    local i
    for (( i = 1; i <= count; i++ )); do
      local reg_token_file="${state_dir}/reg-${repo_short}-${i}.token"
      printf '%s\n' "$reg_token" > "$reg_token_file"
      chmod 0600 "$reg_token_file"

      local container_name="gh-runner-${repo_short}-${i}"
      local runner_name="mlp-${host_tag}-${repo_short}-${i}"
      local work_volume="gh-runner-work-${repo_short}-${i}"

      echo "==> Preparing container ${container_name}..."
      docker rm -f "${container_name}" >/dev/null 2>&1 || true

      echo "==> Starting container ${container_name} for ${owner}/${repo_short} (${i}/${count})..."
      local run_args=(
        -d
        --name "${container_name}"
        --restart unless-stopped
        --cap-drop ALL
        --security-opt no-new-privileges:true
      )
      if [ -n "$cpus" ]; then
        run_args+=(--cpus "$cpus")
      fi
      if [ -n "$memory" ]; then
        run_args+=(--memory "$memory")
      fi
      run_args+=(
        -v "${reg_token_file}:/run/secrets/gh_runner_reg_token"
        -v "${work_volume}:/work"
        -e "REPO_FULL=${owner}/${repo_short}"
        -e "RUNNER_NAME=${runner_name}"
        -e "RUNNER_LABELS=${runner_labels}"
        -e "REG_TOKEN_FILE=/run/secrets/gh_runner_reg_token"
        "${IMAGE_NAME}"
      )

      docker run "${run_args[@]}"
      echo "==> Successfully launched ${container_name}."
    done
    unset reg_token
  done
}

cmd_down() {
  local raw_repos=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)
        shift
        if [ $# -gt 0 ]; then
          raw_repos+=("$1")
        fi
        ;;
      --repo=*)
        raw_repos+=("${1#--repo=}")
        ;;
      *)
        raw_repos+=("$1")
        ;;
    esac
    shift
  done

  if [ ${#raw_repos[@]} -eq 0 ]; then
    read -r -a raw_repos <<< "${GH_RUNNER_REPOS:-$DEFAULT_REPOS}"
  fi

  local state_dir="${GH_RUNNER_STATE_DIR:-${TMPDIR:-/tmp}/gh-runner-state}"
  local count_limit="${GH_RUNNER_COUNT:-1}"
  if [[ ! "$count_limit" =~ ^[1-9][0-9]*$ ]]; then
    count_limit=1
  fi

  for raw in "${raw_repos[@]}"; do
    local parsed
    parsed="$(parse_repo "$raw")"
    local repo_short="${parsed#* }"

    echo "==> Stopping and removing containers for ${repo_short}..."
    docker rm -f "gh-runner-${repo_short}" >/dev/null 2>&1 || true

    local matched_containers
    matched_containers="$(docker ps -a --filter "name=^/gh-runner-${repo_short}-" --format '{{.Names}}' 2>/dev/null | grep -E "^gh-runner-${repo_short}-[0-9]+$" || true)"
    if [ -n "$matched_containers" ]; then
      while IFS= read -r c_name; do
        [ -n "$c_name" ] && docker rm -f "$c_name" >/dev/null 2>&1 || true
      done <<< "$matched_containers"
    fi

    local i
    for (( i = 1; i <= count_limit; i++ )); do
      local c_name="gh-runner-${repo_short}-${i}"
      if [ -z "$matched_containers" ] || ! echo "$matched_containers" | grep -q -x "$c_name"; then
        docker rm -f "$c_name" >/dev/null 2>&1 || true
      fi
    done

    rm -f "${state_dir}/reg-${repo_short}.token" "${state_dir}"/reg-"${repo_short}"-*.token 2>/dev/null || true
    echo "==> Removed containers for ${repo_short}."
  done
}

cmd_status() {
  local raw_repos=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)
        shift
        if [ $# -gt 0 ]; then
          raw_repos+=("$1")
        fi
        ;;
      --repo=*)
        raw_repos+=("${1#--repo=}")
        ;;
      *)
        raw_repos+=("$1")
        ;;
    esac
    shift
  done

  if [ ${#raw_repos[@]} -eq 0 ]; then
    read -r -a raw_repos <<< "${GH_RUNNER_REPOS:-$DEFAULT_REPOS}"
  fi

  local filter_args=()
  for raw in "${raw_repos[@]}"; do
    local parsed
    parsed="$(parse_repo "$raw")"
    local repo_short="${parsed#* }"
    filter_args+=(--filter "name=^/gh-runner-${repo_short}$" --filter "name=^/gh-runner-${repo_short}-")
  done

  echo "==> Listing gh-runner containers for: ${raw_repos[*]}"
  docker ps -a "${filter_args[@]}"
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
