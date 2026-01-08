#!/usr/bin/env bash

set -euo pipefail

# Globals -------------------------------------------------------------------
declare -a __UNTRACKED_BACKUPS=()
declare -a __SUBCONTAINERS_TO_PUSH=()
declare -a __SUBCONTAINERS_TO_CLEAR=()
declare -A __SUBCONTAINER_COMMITS=()
ROOT_TOKEN_FILE=""
ALLOW_PULL=${ALLOW_PULL:-0} # Default is fetch-only; set to 1 to allow automatic pulls/rebases
declare -a DEFAULT_INDEX_EXCLUDES=(
  "node_modules"
  ".eslintcache"
  "__pycache__"
  "pycache"
  "cache"
  "dist"
  "build"
  "whatsapp-mcp/whatsapp-bridge/store/whatsapp.db"
  "whatsapp-mcp/whatsapp-bridge/store/messages.db"
  "gcp-oauth.keys.json"
  "gemini-gcloud-key.json"
  "meus_arquivos_mcp"
  "go/"
  "env.sh"
  ".gemini"
  "venv"
  "logs"
  ".aider*"
  ".cursor*"
)
declare -a SENSITIVE_PATHS=("GITHUB_TOKEN" "GITHUB_TOKEN.txt" "AMO_API_KEY.txt" "AMO_API_SECRET.txt" "gcp-oauth.keys.json" "gemini-gcloud-key.json" "AMO_API_KEY" "AMO_API_SECRET" ".env" "*.env" ".env.*")
SUBCONTAINER_STATE_FILE=".subcontainers"
SUBCONTAINER_MODE=false
ROOT_REMOTE_URL=""
ROOT_REPO_NAME=""
ROOT_REPO_DIR=""
trap '__restore_all_backups; restore_root_remote' EXIT INT TERM

main() {
  local repo_dir repo_name script_rel action current_branch remote_url
  ensure_dependencies

  repo_dir=$(pwd)
  repo_name=$(basename "$repo_dir")
  ROOT_REPO_NAME="$repo_name"
  ROOT_REPO_DIR="$repo_dir"
  script_rel=$(script_relative_path "$repo_dir")
  
  if [[ $# -gt 0 ]]; then
    action=$1
  else
    if [[ -t 0 ]]; then
      action=$(prompt_repo_action "$repo_name")
    else
      action="push"
    fi
  fi

  if [[ "$action" == "reauth" ]]; then
    reauth_all_recursively "$repo_dir"
    echo "Lembrete: Para carregar as variáveis no seu ambiente atual, execute com 'source' (ex: source ./create_and_push_repo.sh reauth)." >&2
    return
  fi

  ensure_token
  ensure_git_lfs

  init_git_repo
  current_branch=$(ensure_main_branch)
  remote_url=$(resolve_remote_url "$repo_name")
  ROOT_REMOTE_URL="$remote_url"

  case "$action" in
    push)
      SUBCONTAINER_MODE=false
      ensure_remote_repo_exists "$repo_name" "$(repo_visibility_from_folder "$repo_name")"
      ensure_remote "$remote_url"
      sync_with_remote "$current_branch"
      perform_push "$script_rel" "$current_branch" "$remote_url"
      ensure_remote "$remote_url"
      ;; 
    push-subfolders)
      SUBCONTAINER_MODE=true
      prepare_subcontainer_plan "$repo_name"
      ensure_remote_repo_exists "$repo_name" "$(repo_visibility_from_folder "$repo_name")"
      ensure_remote "$remote_url"
      sync_with_remote "$current_branch"
      ensure_subcontainers_ready
      perform_push "$script_rel" "$current_branch" "$remote_url"
      ensure_remote "$remote_url"
      clear_removed_subcontainers
      ;; 
    push-subfolders-releases)
      SUBCONTAINER_MODE=true
      prepare_subcontainer_plan "$repo_name"
      ensure_remote_repo_exists "$repo_name" "$(repo_visibility_from_folder "$repo_name")"
      ensure_remote "$remote_url"
      sync_with_remote "$current_branch"
      ensure_subcontainers_ready_with_releases
      perform_push "$script_rel" "$current_branch" "$remote_url"
      ensure_remote "$remote_url"
      clear_removed_subcontainers
      ;; 
    push-recursive)
      push_recursive_all
      ;; 
    sync-scripts)
      sync_scripts_recursively
      ;;
    push-firefox-amo-github)
      SUBCONTAINER_MODE=false
      ensure_amo_credentials
      if ! submit_extension_to_amo; then
        echo "Aviso: Falha na submissão ao AMO. Continuando com push para GitHub..." >&2
      fi
      ensure_remote_repo_exists "$repo_name" "$(repo_visibility_from_folder "$repo_name")"
      ensure_remote "$remote_url"
      sync_with_remote "$current_branch"
      perform_push "$script_rel" "$current_branch" "$remote_url"
      ensure_remote "$remote_url"
      ;; 
    *)
      echo "Unknown action '$action'." >&2
      exit 1
      ;; 
  esac
}

# Dependency / token helpers -------------------------------------------------
ensure_dependencies() {
  local dep
  for dep in git curl python3 git-lfs web-ext; do
    if ! command -v "$dep" >/dev/null 2>&1; then
      echo "Error: dependency '$dep' was not found in PATH." >&2
      exit 1
    fi
  done
}

ensure_git_lfs() {
  if ! command -v git-lfs >/dev/null 2>&1; then
    echo "Error: git-lfs is required but not installed." >&2
    exit 1
  fi
  git lfs install --skip-repo >/dev/null 2>&1 || true
}

ensure_token() {
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    ROOT_TOKEN_FILE=$(pwd)/GITHUB_TOKEN.txt
    return
  fi

  local token_file
  if token_file=$(find_token_file); then
    if load_token_from_file "$token_file"; then
      export GITHUB_TOKEN
      ROOT_TOKEN_FILE="$token_file"
      return
    fi
  fi

  echo "Error: provide GITHUB_TOKEN via environment variable or file." >&2
  exit 1
}

find_token_file() {
  local dir=$PWD candidate
  while true; do
    for candidate in "$dir/GITHUB_TOKEN" "$dir/GITHUB_TOKEN.txt"; do
      if [[ -f "$candidate" ]]; then
        printf "%s\n" "$candidate"
        return 0
      fi
    done
    if [[ "$dir" == "/" ]]; then
      break
    fi
    dir=$(dirname "$dir")
  done
  return 1
}

load_token_from_file() {
  local token_file=$1 token
  token=$(python3 - "$token_file" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
try:
    text = path.read_text(encoding="utf-8")
except Exception:
    sys.exit(1)
line = text.splitlines()[0] if text else ""
print(line.lstrip("\ufeff"), end="")
PY
) || return 1

  if [[ -n "$token" ]]; then
    GITHUB_TOKEN=$token
    ROOT_TOKEN_FILE="$token_file"
    return 0
  fi
  return 1
}

propagate_credentials_to_subdir() {
  local subdir=$1

  # GitHub - Propagate to all subrepos
  local gh_target="$subdir/GITHUB_TOKEN.txt"
  if [[ -n "$ROOT_TOKEN_FILE" && -f "$ROOT_TOKEN_FILE" ]]; then
    cp "$ROOT_TOKEN_FILE" "$gh_target"
  elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
    printf "%s\n" "$GITHUB_TOKEN" >"$gh_target"
  fi
  chmod 600 "$gh_target" 2>/dev/null || true

  # Check if subdir is a Firefox extension project
  local is_firefox_extension=false
  if [[ -n $(find "$subdir" -maxdepth 1 -name "manifest*.json" -print -quit) ]] || \
     [[ -n $(find "$subdir" -maxdepth 1 -name "*.xpi" -print -quit) ]]; then
    is_firefox_extension=true
  fi

  if [[ "$is_firefox_extension" == "false" ]]; then
    return
  fi

  # AMO Key - Propagate only to extensions
  local amo_key_target="$subdir/AMO_API_KEY.txt"
  if [[ -f "AMO_API_KEY.txt" ]]; then
    cp "AMO_API_KEY.txt" "$amo_key_target"
    chmod 600 "$amo_key_target" 2>/dev/null || true
  elif [[ -n "${AMO_API_KEY:-}" ]]; then
     printf "%s\n" "$AMO_API_KEY" >"$amo_key_target"
     chmod 600 "$amo_key_target" 2>/dev/null || true
  fi

  # AMO Secret - Propagate only to extensions
  local amo_secret_target="$subdir/AMO_API_SECRET.txt"
  if [[ -f "AMO_API_SECRET.txt" ]]; then
    cp "AMO_API_SECRET.txt" "$amo_secret_target"
    chmod 600 "$amo_secret_target" 2>/dev/null || true
  elif [[ -n "${AMO_API_SECRET:-}" ]]; then
     printf "%s\n" "$AMO_API_SECRET" >"$amo_secret_target"
     chmod 600 "$amo_secret_target" 2>/dev/null || true
  fi
}

reauth_github_token() {
  local repo_dir=${1:-$PWD} token target login=""
  target="$repo_dir/GITHUB_TOKEN.txt"

  echo "Re-authenticating GitHub token. It will be saved to: $target" >&2
  read -rsp "Enter new GitHub PAT (input hidden, leave blank to skip): " token
  echo
  if [[ -z "$token" ]]; then
    echo "GitHub token update skipped." >&2
    return
  fi

  printf "%s\n" "$token" >"$target"
  chmod 600 "$target" 2>/dev/null || true
  
  local central_target="/home/lucas/Downloads/GITHUB_TOKEN.txt"
  if [[ "$(realpath "$target")" != "$(realpath "$central_target")" ]]; then
     cp "$target" "$central_target"
     chmod 600 "$central_target" 2>/dev/null || true
     echo "Token backup updated at $central_target" >&2
  fi

  export GITHUB_TOKEN="$token"
  ROOT_TOKEN_FILE="$target"

  if validate_github_token "$token" login; then
    echo "Token validated for GitHub user '$login' and saved to $target" >&2
  else
    echo "Token saved to $target but validation failed. Check scopes/network." >&2
  fi
}

validate_github_token() {
  local token=$1 login_var=$2 tmp status login=""
  tmp=$(mktemp)
  status=$(curl -sS -w "%{http_code}" -o "$tmp" \
    -H "Authorization: token $token" \
    -H "Accept: application/vnd.github+json" \
    https://api.github.com/user)
  if [[ "$status" != "200" ]]; then
    rm -f "$tmp"
    return 1
  fi

  login=$(python3 - "$tmp" <<'PY'
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        data = json.load(fh)
    print(data.get("login", ""))
except Exception:
    pass
PY
)
  rm -f "$tmp"
  if [[ -n "$login_var" ]]; then
    printf -v "$login_var" '%s' "$login"
  fi
  return 0
}

reauth_amo_credentials() {
  local repo_dir=$1 key secret
  local key_file="$repo_dir/AMO_API_KEY.txt"
  local secret_file="$repo_dir/AMO_API_SECRET.txt"
  local central_key="/home/lucas/Downloads/AMO_API_KEY.txt"
  local central_secret="/home/lucas/Downloads/AMO_API_SECRET.txt"

  echo "Updating AMO Credentials..." >&2
  read -rsp "Enter AMO API Key (Issuer): " key
  echo
  if [[ -n "$key" ]]; then
    printf "%s\n" "$key" >"$key_file"
    chmod 600 "$key_file" 2>/dev/null || true
    
    if [[ "$(realpath "$key_file")" != "$(realpath "$central_key")" ]]; then
      cp "$key_file" "$central_key"
      chmod 600 "$central_key" 2>/dev/null || true
      echo "AMO Key backup updated at $central_key" >&2
    fi
    
    export AMO_API_KEY="$key"
    echo "AMO API Key saved to $key_file" >&2
  fi

  read -rsp "Enter AMO API Secret: " secret
  echo
  if [[ -n "$secret" ]]; then
    printf "%s\n" "$secret" >"$secret_file"
    chmod 600 "$secret_file" 2>/dev/null || true
    
    if [[ "$(realpath "$secret_file")" != "$(realpath "$central_secret")" ]]; then
      cp "$secret_file" "$central_secret"
      chmod 600 "$central_secret" 2>/dev/null || true
      echo "AMO Secret backup updated at $central_secret" >&2
    fi

    export AMO_API_SECRET="$secret"
    echo "AMO API Secret saved to $secret_file" >&2
  fi
}

reauth_all_recursively() {
  local repo_dir=$1
  
  # 1. GitHub
  reauth_github_token "$repo_dir"

  # 2. AMO
  echo
  read -rp "Do you want to update Firefox AMO credentials? [y/N] " yesno
  if [[ "$yesno" =~ ^[Yy]$ ]]; then
    reauth_amo_credentials "$repo_dir"
  fi

  # 3. Recursion
  echo
  echo "Propagating credentials to immediate subdirectories..."
  local base_dir=$repo_dir
  local path subdir
  while IFS= read -r -d '' path; do
    subdir=${path#"$base_dir"/}
    [[ -z "$subdir" || "${subdir:0:1}" == "." ]] && continue
    
    if [[ -f "$path/create_and_push_repo.sh" ]]; then
       echo "  -> $subdir"
       propagate_credentials_to_subdir "$path"
    fi
  done < <(find "$base_dir" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
  echo "Credentials propagation complete."
}

# AMO Credentials ------------------------------------------------------------
ensure_amo_credentials() {
  local missing=0

  if ! load_secret_into_var AMO_API_KEY AMO_API_KEY AMO_API_KEY.txt; then
    create_secret_placeholder AMO_API_KEY.txt "chave AMO API Key"
    echo "Erro: defina AMO_API_KEY ou crie AMO_API_KEY(.txt)." >&2
    missing=1
  fi

  if ! load_secret_into_var AMO_API_SECRET AMO_API_SECRET AMO_API_SECRET.txt; then
    create_secret_placeholder AMO_API_SECRET.txt "chave AMO API Secret"
    echo "Erro: defina AMO_API_SECRET ou crie AMO_API_SECRET(.txt)." >&2
    missing=1
  fi

  if [[ $missing -ne 0 ]]; then
    echo "Dica: gere as credenciais em https://addons.mozilla.org/developers/addon/api/key e cole a chave/segredo na primeira linha de cada arquivo." >&2
    exit 1
  fi
}

create_secret_placeholder() {
  local filename=$1
  local label=$2
  local amo_url="https://addons.mozilla.org/developers/addon/api/key"

  if [[ -e "$filename" ]]; then
    return
  fi

  cat >"$filename" <<EOF

# Cole sua $label na primeira linha deste arquivo.
# Gere novas credenciais no Portal de Desenvolvedores do Firefox: $amo_url
EOF

  echo "Arquivo '$filename' criado." >&2
  echo "Acesse $amo_url para gerar a sua $label e cole o valor na primeira linha de '$filename'." >&2
}

load_secret_into_var() {
  local var_name=$1
  shift

  if [[ -n "${!var_name:-}" ]]; then
    return 0
  fi

  local value candidate
  for candidate in "$@"; do
    if [[ -f "$candidate" ]]; then
      value=$(read_first_line "$candidate") || continue
      if [[ -n "$value" ]]; then
        printf -v "$var_name" '%s' "$value"
        export "$var_name"
        return 0
      fi
    fi
  done

  return 1
}

read_first_line() {
  local path=$1
  python3 - "$path" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    text = path.read_text(encoding="utf-8")
except Exception:
    sys.exit(1)

line = text.splitlines()[0] if text else ""
print(line.lstrip("\ufeff"), end="")
PY
}

# AMO Submission -------------------------------------------------------------
submit_extension_to_amo() {
  local channel=${AMO_CHANNEL:-listed}
  ensure_webext_ignore

  local artifacts_dir=${AMO_ARTIFACTS_DIR:-.web-ext-artifacts}
  mkdir -p "$artifacts_dir"

  # Manifest Swapping Logic
  local original_manifest="manifest.json"
  local firefox_manifest=""
  local backup_manifest="manifest.json.bak_amo"
  local swapped=0

  if [[ -f "manifest-firefox-mv3.json" ]]; then
    firefox_manifest="manifest-firefox-mv3.json"
  elif [[ -f "manifest-firefox-mv2.json" ]]; then
    firefox_manifest="manifest-firefox-mv2.json"
  fi

  if [[ -n "$firefox_manifest" ]]; then
    echo "Hybrid repo detected: Swapping $firefox_manifest to manifest.json for AMO submission..." >&2
    if [[ -f "$original_manifest" ]]; then
      cp "$original_manifest" "$backup_manifest"
    fi
    cp "$firefox_manifest" "$original_manifest"
    swapped=1
  fi

  # AUTO-FIX VALIDATION ERRORS
  fix_manifest_errors "$original_manifest"

  # Check version to avoid redundant submission
  local current_version last_version
  current_version=$(python3 -c "import json, sys; print(json.load(open('$original_manifest')).get('version', ''))" 2>/dev/null || echo "")
  
  if [[ -f ".amo-last-version" ]]; then
    last_version=$(cat ".amo-last-version")
  else
    last_version=""
  fi

  if [[ -n "$current_version" && "$current_version" == "$last_version" ]]; then
    echo "AMO: Version $current_version already submitted. Skipping." >&2
    # Restore Original Manifest if swapped
    if [[ $swapped -eq 1 ]]; then
      if [[ -f "$backup_manifest" ]]; then
        mv "$backup_manifest" "$original_manifest"
      else
        rm "$original_manifest"
      fi
    fi
    return 0
  fi

  local metadata_file=${AMO_METADATA_FILE:-amo-metadata.json}
  if [[ ! -f "$metadata_file" ]]; then
    cat >"$metadata_file" <<'EOF'
{
  "version": {
    "custom_license": {
      "name": {
        "en-US": "Mozilla Public License 2.0"
      },
      "text": {
        "en-US": "Mozilla Public License 2.0. Full text: https://www.mozilla.org/MPL/2.0/"
      }
    }
  }
}
EOF
  fi

  local cmd=(web-ext sign
    --api-key "$AMO_API_KEY"
    --api-secret "$AMO_API_SECRET"
    --channel "$channel"
    --artifacts-dir "$artifacts_dir"
    --amo-metadata "$metadata_file"
    --ignore-files "AMO_API_KEY.txt" "AMO_API_SECRET.txt" "GITHUB_TOKEN.txt" "create_and_push_repo.sh" "create_firefox-amo_push_github.sh" "*.sh" ".env*" "screenshots/" ".git/" ".web-ext-artifacts/"
  )

  if [[ -n "${AMO_SOURCE_DIR:-}" ]]; then
    cmd+=(--source-dir "$AMO_SOURCE_DIR")
  fi

  echo "Enviando extensão ao Firefox AMO (canal: $channel)..." >&2
  
  local final_status=0
  
  # LOOP FOR RETRY (THROTTLING)
  while true; do
      set +e
      # Execute web-ext in background and monitor output for early success
      rm -f web-ext-output.log
      "${cmd[@]}" > web-ext-output.log 2>&1 &
      local pid=$!
      
      local start_time=$(date +%s)
      local max_wait=600 # 10 min hard timeout
      local found_success=0
      
      echo "Monitorando submissão (PID $pid)..." >&2
      
      # Wait for log creation
      while [[ ! -f web-ext-output.log ]] && kill -0 $pid 2>/dev/null; do sleep 0.5; done

      while kill -0 $pid 2>/dev/null; do
        if (( $(date +%s) - start_time > max_wait )); then
          echo "Timeout atingido. Encerrando..." >&2
          kill $pid
          break
        fi

        if grep -Eq "Waiting for approval|Your add-on has been submitted|Validation results:" web-ext-output.log; then
           echo "Sucesso na submissão detectado! Encerrando espera..." >&2
           kill $pid 2>/dev/null || true
           found_success=1
           break
        fi
        
        sleep 2
      done
      
      wait $pid 2>/dev/null
      local exit_code=$?
      set -e
      
      if [[ $found_success -eq 1 ]]; then
        final_status=0
        break # Success!
      else
        final_status=$exit_code
      fi

      if [[ $final_status -ne 0 ]]; then
          # Check for Throttling
          local wait_seconds
          wait_seconds=$(python3 - <<'PY'
import sys, re
try:
    with open("web-ext-output.log", "r", encoding="utf-8", errors="ignore") as f:
        content = f.read()
        m = re.search(r"Expected available in (\d+) seconds", content)
        if m:
            print(m.group(1))
except:
    pass
PY
)
          if [[ -n "$wait_seconds" ]]; then
              local max_allowed_wait=300
              if (( wait_seconds > max_allowed_wait )); then
                  echo "Aviso: O tempo de espera do AMO ($wait_seconds s) excede o limite de ${max_allowed_wait}s. Pulando submissão..." >&2
                  final_status=1
                  break
              fi
              local sleep_time=$((wait_seconds + 5))
              echo "Throttling detectado. O AMO pediu para esperar $wait_seconds segundos." >&2
              echo "Aguardando $sleep_time segundos antes de tentar novamente..." >&2
              sleep "$sleep_time"
              echo "Retentando..." >&2
              continue # Retry loop
          else
              # Not a throttling error, break and fail
              cat web-ext-output.log >&2
              break
          fi
      else
          # Success (exit code 0 natural)
          echo "Log de sucesso (tail):" >&2
          tail -n 5 web-ext-output.log >&2
          
          # UPDATE LAST SUCCESSFUL VERSION
          if [[ -n "$current_version" ]]; then
             echo "$current_version" > ".amo-last-version"
          fi
          
          break
      fi
  done
  
  rm -f web-ext-output.log

  # Restore Original Manifest
  if [[ $swapped -eq 1 ]]; then
    echo "Restoring original manifest..." >&2
    if [[ -f "$backup_manifest" ]]; then
      mv "$backup_manifest" "$original_manifest"
    else
      rm "$original_manifest"
    fi
  fi

  if [[ $final_status -ne 0 ]]; then
    echo "Erro: Falha na submissão ao AMO. (Status $final_status)" >&2
    return 1
  fi

  echo "Submissão ao AMO concluída com sucesso." >&2
  return 0
}

ensure_webext_ignore() {
  local ignore_file=".web-extignore"
  local entries=(
    ".git"
    ".github"
    ".web-ext-artifacts"
    "GITHUB_TOKEN"
    "GITHUB_TOKEN.txt"
    "AMO_API_KEY"
    "AMO_API_KEY.txt"
    "AMO_API_SECRET",
    "AMO_API_SECRET.txt",
    "gemini-gcloud-key.json",
    "create_and_push_repo.sh",
    "create_firefox-amo_push_github.sh"
    "install-addon-policy.sh"
    "README.md"
    "updates.json"
    "screenshots"
    ".env"
    "*.env"
    ".env.*"
    "*.sh" 
  )

  # Ensure file exists
  touch "$ignore_file"

  # Append missing entries
  for entry in "${entries[@]}"; do
    if ! grep -Fq "$entry" "$ignore_file"; then
       printf "%s\n" "$entry" >>"$ignore_file"
    fi
  done
}

fix_manifest_errors() {
  local manifest_file=$1
  local folder_name
  folder_name=$(basename "$PWD")

  echo "Running auto-fixer on $manifest_file..." >&2

  python3 - "$manifest_file" "$folder_name" <<'PY'
import sys, json, os

manifest_path = sys.argv[1]
folder_name = sys.argv[2]

try:
    with open(manifest_path, 'r', encoding="utf-8") as f:
        data = json.load(f)
    
    changed = False

    # 1. Ensure browser_specific_settings.gecko.id exists
    if "browser_specific_settings" not in data:
        data["browser_specific_settings"] = {}
        changed = True
    
    if "gecko" not in data["browser_specific_settings"]:
        data["browser_specific_settings"]["gecko"] = {}
        changed = True
        
    if "id" not in data["browser_specific_settings"]["gecko"]:
        # Generate ID based on folder name
        # Sanitize folder name for ID
        sanitized = "".join(c if c.isalnum() else "-" for c in folder_name).lower()
        generated_id = f"{sanitized}@luascfl"
        data["browser_specific_settings"]["gecko"]["id"] = generated_id
        changed = True
        print(f"Auto-Fix: Added ID {generated_id}")

    # 2. Fix Data Collection Permissions (required for Gecko)
    if "data_collection_permissions" not in data["browser_specific_settings"]["gecko"]:
         data["browser_specific_settings"]["gecko"]["data_collection_permissions"] = {
             "required": ["none"],
             "optional": [],
             "has_previous_consent": False
         }
         changed = True
         print("Auto-Fix: Added default data_collection_permissions")

    # 3. Fix MV3 Service Worker -> Background Scripts (Firefox compat)
    # Firefox MV3 uses "background": { "scripts": ["file.js"] } instead of "service_worker"
    if data.get("manifest_version") == 3:
        bg = data.get("background", {})
        if "service_worker" in bg:
            sw_file = bg["service_worker"]
            del data["background"]["service_worker"]
            data["background"]["scripts"] = [sw_file]
            # Often useful to set type: module implies strict mode, 
            # but usually just swapping key is enough for basic shim.
            changed = True
            print(f"Auto-Fix: Converted background.service_worker to background.scripts for Firefox")

    if changed:
        with open(manifest_path, 'w', encoding="utf-8") as f:
            json.dump(data, f, indent=2)
            f.write('\n')
except Exception as e:
    print(f"Error fixing manifest: {e}", file=sys.stderr)
    sys.exit(1)
PY
}
# Repo setup -----------------------------------------------------------------
script_relative_path() {
  local repo_dir=$1
  if command -v realpath >/dev/null 2>&1; then
    realpath --relative-to="$repo_dir" "$0" 2>/dev/null || basename "$0"
    return
  fi

  python3 - "$repo_dir" "$0" <<'PY'
import os, sys
repo, script = map(os.path.abspath, sys.argv[1:])
try:
    print(os.path.relpath(script, repo))
except ValueError:
    print(os.path.basename(script))
PY
}

prompt_repo_action() {
  local repo_name=$1 choice
  echo "----------------------------------------------------------------"
  echo "Create and Push Repo Script"
  echo "----------------------------------------------------------------"
  echo "This script manages git repositories, handling authentication,"
  echo "remote creation, and recursive operations for subfolders."
  echo ""
  echo "Available Actions:"
  echo "  push            : Pushes the current directory as a single repo."
  echo "  push-recursive  : Scans subfolders and pushes them individually,"
  echo "                    detecting special types (Codex, Firefox Ext,"
  echo "                    Releases) automatically."
  echo "  reauth          : Updates GitHub/AMO credentials."
  echo "----------------------------------------------------------------"
  
  while true; do
    if ! read -rp "Choose action for repository '$repo_name' [push/push-recursive/reauth] (default: push): " choice; then
      choice=""
    fi
    case "${choice,,}" in
      ""|push) echo "push"; return ;;
      push-subfolders|push+subfolders|push_subfolders)
        echo "push-subfolders"
        return
      ;;
      push-subfolders-releases|push_subfolders_releases)
        echo "push-subfolders-releases"
        return
      ;;
      push-recursive|push_recursive|recursive)
        echo "push-recursive"
        return
        ;;      push-firefox-amo-github|push_firefox_amo_github)
        # Keep hidden but functional if typed manually
        echo "push-firefox-amo-github"
        return
        ;;
      reauth|auth|token)
        echo "reauth"
        return
        ;;
      *) echo "Invalid input. Type 'push', 'push-subfolders-releases', 'push-recursive', or 'reauth'." >&2 ;; 
    esac
  done
}

init_git_repo() {
  if [[ ! -d .git ]]; then
    git init >/dev/null 2>&1
  fi
}

ensure_main_branch() {
  local current
  current=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  if [[ -z "$current" || "$current" == "HEAD" ]]; then
    git symbolic-ref HEAD refs/heads/main >/dev/null 2>&1 || git branch -M main
    current="main"
  elif [[ "$current" != "main" ]]; then
    git branch -M "$current" main
    current="main"
  fi
  echo "$current"
}

resolve_remote_url() {
  local repo_name=$1
  case "${GITHUB_REMOTE_PROTOCOL:-https}" in
    ssh) echo "git@github.com:luascfl/$repo_name.git" ;; 
    https|*) echo "https://github.com/luascfl/$repo_name.git" ;; 
  esac
}

repo_visibility_from_folder() {
  local folder_name=$1
  if [[ "$folder_name" == tmp_* ]]; then
    echo "private"
  else
    echo "public"
  fi
}

ensure_remote_repo_exists() {
  local repo_name=$1 visibility=${2:-public} private_flag
  case "$visibility" in
    private|true|1) private_flag=true ;; 
    *) private_flag=false ;; 
  esac

  # OPTIMIZATION: Check if repo exists to avoid Rate Limit on Creation (POST)
  local check_status
  check_status=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: token $GITHUB_TOKEN" \
    "https://api.github.com/repos/luascfl/$repo_name")
  
  if [[ "$check_status" == "200" ]]; then
     # Repository exists, skip creation
     return
  fi

  local response http_status
  response=$(mktemp)
  http_status=$(curl -sS -w "%{http_code}" -o "$response" \
    -X POST "https://api.github.com/user/repos" \
    -H "Authorization: token $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -d "{\"name\":\"$repo_name\",\"private\":$private_flag}")

  case "$http_status" in
    201) ;; 
    422) echo "Warning: repository '$repo_name' already exists in luascfl. Continuing." >&2 ;; 
    *) echo "Error creating repository (status $http_status):" >&2
       cat "$response" >&2
       rm -f "$response"
       exit 1 ;; 
  esac
  rm -f "$response"
}

ensure_remote() {
  local expected=$1 repo_path=${ROOT_REPO_DIR:-.}
  if git -C "$repo_path" remote get-url origin >/dev/null 2>&1; then
    local current
    current=$(git -C "$repo_path" remote get-url origin)
    if [[ "$current" != "$expected" ]]; then
      echo "Remote 'origin' pointed to $current. Updating to $expected." >&2
      git -C "$repo_path" remote set-url origin "$expected"
    fi
  else
    git -C "$repo_path" remote add origin "$expected"
  fi
}

restore_root_remote() {
  if [[ -z "${ROOT_REMOTE_URL:-}" ]]; then
    return
  fi
  ensure_remote "$ROOT_REMOTE_URL"
}

# Sync -----------------------------------------------------------------------
sync_with_remote() {
  local branch=$1 allow_pull=${2:-$ALLOW_PULL}
  if git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
    echo "Remote branch '$branch' found. Fetching (no pull by default)..." >&2
    if ! git fetch --prune --no-tags origin "$branch"; then
      echo "Warning: fetch failed; skipping sync." >&2
      return 1
    fi

    local local_rev remote_rev base
    local_rev=$(git rev-parse HEAD)
    remote_rev=$(git rev-parse "origin/$branch")
    base=$(git merge-base HEAD "origin/$branch" 2>/dev/null || true)

    if [[ "$local_rev" == "$remote_rev" ]]; then
      echo "Already in sync with origin/$branch." >&2
      return 0
    fi

    if [[ "$local_rev" == "$base" ]]; then
      echo "Local is behind origin/$branch. Pull required." >&2
      if [[ "$allow_pull" == "1" ]]; then
        pull_with_credentials "$branch" && return 0
        echo "Pull failed; please resolve manually." >&2
        return 1
      fi
      echo "Skipping pull to protect local work. Set ALLOW_PULL=1 or run the 'pull' action to enable." >&2
      exit 1
    fi

    if [[ "$remote_rev" == "$base" ]]; then
      echo "Local is ahead of origin/$branch; proceeding without pull." >&2
      return 0
    fi

    echo "Local and origin/$branch have diverged. Pull/rebase required." >&2
    if [[ "$allow_pull" == "1" ]]; then
      pull_with_credentials "$branch" && return 0
      echo "Pull failed; please resolve manually." >&2
      return 1
    fi
    echo "Skipping pull to protect local work. Set ALLOW_PULL=1 or run the 'pull' action to enable." >&2
    exit 1
  else
    echo "Remote branch '$branch' not found. Assuming first push/pull." >&2
  fi
}

# Push -----------------------------------------------------------------------
perform_push() {
  local script_rel=$1 branch=$2 remote_url=$3
  stage_files_excluding_script "$script_rel"
  if commit_changes; then
    echo "Commit created." >&2
  else
    echo "No changes to commit." >&2
  fi

  if push_with_credentials "$branch"; then
    echo "Push completed successfully: $remote_url"
  else
    echo "Push failed." >&2
    exit 1
  fi
}

push_recursive_all() {
  local base_dir
  local -a pushed=()
  local -a failed=()
  local -a ignored=()
  local path subdir script action found_xpi

  base_dir=$(pwd)
  echo "==> Starting recursive push for all known types..." >&2

  while IFS= read -r -d '' path; do
    subdir=${path#"$base_dir"/}
    [[ -z "$subdir" ]] && continue
    if [[ "${subdir:0:1}" == "." ]]; then
      continue
    fi
    
    # 1. Determine type/action
    action=""
    
    if [[ "$subdir" == releases* ]]; then
        action="push-subfolders-releases"
    elif [[ "$subdir" == codex* ]]; then
        action="push-subfolders"
    elif [[ -n $(find "$path" -maxdepth 1 -name "*.xpi" -print -quit) ]]; then
        action="push-firefox-amo-github"
    elif [[ -f "$path/create_and_push_repo.sh" ]]; then
        action="push"
    else
        ignored+=("$subdir (not a managed repo)")
        continue
    fi
    
    script="$path/create_and_push_repo.sh"
    
    propagate_credentials_to_subdir "$path"
    
    # Update/Install script
    cp "$base_dir/create_and_push_repo.sh" "$script"
    chmod +x "$script" >/dev/null 2>&1 || true

    echo "==> Recursive processing: '$subdir' (Action: $action)..." >&2
    if (
      cd "$path" && \
      export AMO_API_KEY="${AMO_API_KEY:-}" && \
      export AMO_API_SECRET="${AMO_API_SECRET:-}" && \
      ./create_and_push_repo.sh "$action" < /dev/null
    ); then
      pushed+=("$subdir ($action)")
    else
      failed+=("$subdir ($action)")
    fi
    sleep 2 # Prevent rate-limiting
  done < <(find "$base_dir" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)

  printf '\npush-recursive-all summary:\n' >&2
  printf '  processed:\n' >&2
  if [[ ${#pushed[@]} -gt 0 ]]; then
    for entry in "${pushed[@]}"; do printf '    - %s\n' "$entry" >&2; done
  else
    printf '    (none)\n' >&2
  fi
  printf '  failures:\n' >&2
  if [[ ${#failed[@]} -gt 0 ]]; then
    for entry in "${failed[@]}"; do printf '    - %s\n' "$entry" >&2; done
  else
    printf '    (none)\n' >&2
  fi
  printf '  ignored:\n' >&2
  if [[ ${#ignored[@]} -gt 0 ]]; then
    for entry in "${ignored[@]}"; do printf '    - %s\n' "$entry" >&2; done
  else
    printf '    (none)\n' >&2
  fi
}

prepare_subcontainer_plan() {
  local root_repo_name=$1
  __SUBCONTAINERS_TO_PUSH=()
  __SUBCONTAINERS_TO_CLEAR=()
  __SUBCONTAINER_COMMITS=()

  declare -A previous=()
  if [[ -f "$SUBCONTAINER_STATE_FILE" ]]; then
    while IFS="|" read -r prev_dir prev_repo; do
      [[ -z "$prev_dir" || -z "$prev_repo" ]] && continue
      previous["$prev_dir"]="$prev_repo"
    done <"$SUBCONTAINER_STATE_FILE"
  fi

  declare -A current=()
  local -a subdirs=()
  while IFS= read -r -d '' path; do
    path=${path#./}
    [[ "$path" == ".git" ]] && continue
    [[ "$path" == .* ]] && continue
    [[ "$path" == "venv" ]] && continue
    [[ "$path" == "logs" ]] && continue
    
    # Skip excluded items from DEFAULT_INDEX_EXCLUDES
    local excluded=false
    for skip in "${DEFAULT_INDEX_EXCLUDES[@]}"; do
      if [[ "$path" == "$skip" ]]; then
        excluded=true
        break
      fi
    done
    [[ "$excluded" == "true" ]] && continue

    subdirs+=("$path")
  done < <(find . -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null || true)

  local subdir repo_name visibility
  for subdir in "${subdirs[@]}"; do
    repo_name=$(format_subcontainer_repo_name "$root_repo_name" "$subdir")
    visibility=$(repo_visibility_from_folder "$subdir")
    current["$subdir"]="$repo_name"
    __SUBCONTAINERS_TO_PUSH+=("$subdir|$repo_name|$visibility")
  done

  local prev_dir
  for prev_dir in "${!previous[@]}"; do
    if [[ -z "${current[$prev_dir]+_}" ]]; then
      __SUBCONTAINERS_TO_CLEAR+=("$prev_dir|${previous[$prev_dir]}")
      remove_submodule_config "$prev_dir"
    fi
  done

  {
    for subdir in "${!current[@]}"; do
      printf "%s|%s\n" "$subdir" "${current[$subdir]}"
    done | sort
  } >"$SUBCONTAINER_STATE_FILE"
}

ensure_subcontainers_ready() {
  if [[ ${#__SUBCONTAINERS_TO_PUSH[@]} -eq 0 ]]; then
    echo "No subfolders detected to manage as submodules." >&2
    return
  fi

  local entry subdir repo visibility
  for entry in "${__SUBCONTAINERS_TO_PUSH[@]}"; do
    IFS="|" read -r subdir repo visibility <<<"$entry"
    ensure_single_subcontainer_ready "$subdir" "$repo" "$visibility"
  done
}

ensure_subcontainers_ready_with_releases() {
  if [[ ${#__SUBCONTAINERS_TO_PUSH[@]} -eq 0 ]]; then
    echo "No subfolders detected to manage as submodules." >&2
    return
  fi

  local entry subdir repo visibility
  for entry in "${__SUBCONTAINERS_TO_PUSH[@]}"; do
    IFS="|" read -r subdir repo visibility <<<"$entry"
    ensure_single_subcontainer_ready "$subdir" "$repo" "$visibility"
    create_release_for_subdir "$subdir" "$repo"
  done
}

create_release_for_subdir() {
  local subdir=$1 repo_name=$2
  
  # Find APK file
  local apk_file
  apk_file=$(find "$subdir" -maxdepth 1 -name "*.apk" -print -quit)
  
  if [[ -z "$apk_file" ]]; then
    echo "No APK found in $subdir, skipping release creation." >&2
    return
  fi
  
  local filename
  filename=$(basename "$apk_file")
  
  # Extract version from filename (e.g., AppName_v1.2.3.apk -> v1.2.3)
  local version
  if [[ "$filename" =~ v([0-9]+\.[0-9]+(\.[0-9]+)?) ]]; then
    version="v${BASH_REMATCH[1]}"
  else
    # Fallback to timestamp if no version found
    version="release-$(date +%Y%m%d-%H%M%S)"
  fi
  
  echo "Verifying release $version for $repo_name..." >&2
  
  # Create tag
  git -C "$subdir" tag -a "$version" -m "Release $version" 2>/dev/null || true
  
  # Push tag
  if [[ "${GITHUB_REMOTE_PROTOCOL:-https}" == "https" ]]; then
    run_with_https_credentials git -C "$subdir" push origin "$version" >/dev/null 2>&1 || true
  else
    git -C "$subdir" push origin "$version" >/dev/null 2>&1 || true
  fi
  
  # Create Release via API using Python
  python3 - "$repo_name" "$version" "$apk_file" "$GITHUB_TOKEN" <<'PY'
import sys, requests, os

repo, tag, apk_path, token = sys.argv[1:]
filename = os.path.basename(apk_path)
headers = {'Authorization': f'token {token}', 'Accept': 'application/vnd.github.v3+json'}

# 1. Get or Create Release
url = f'https://api.github.com/repos/luascfl/{repo}/releases/tags/{tag}'
r = requests.get(url, headers=headers)

if r.status_code == 404:
    print(f"Creating new release for {tag}...")
    url_create = f'https://api.github.com/repos/luascfl/{repo}/releases'
    data = {'tag_name': tag, 'name': f'Release {tag}', 'body': 'Automated release', 'draft': False, 'prerelease': False}
    r = requests.post(url_create, headers=headers, json=data)
    if r.status_code != 201:
        print(f"Error creating release: {r.text}")
        sys.exit(1)
    release = r.json()
else:
    # Release exists, silently proceed
    release = r.json()

# 2. Upload Asset
upload_url = release['upload_url'].replace('{?name,label}', '')
existing_assets = [a['name'] for a in release.get('assets', [])]

if filename in existing_assets:
    print(f"Asset {filename} already present.")
elif os.path.exists(apk_path):
    print(f"Uploading {filename}...")
    with open(apk_path, 'rb') as f:
        data = f.read()
    
    headers_upload = headers.copy()
    headers_upload['Content-Type'] = 'application/vnd.android.package-archive'
    
    r_up = requests.post(f'{upload_url}?name={filename}', headers=headers_upload, data=data)
    if r_up.status_code == 201:
        print(f"Success! Download link: {r_up.json().get('browser_download_url')}")
    elif r_up.status_code == 422:
        print("Asset already uploaded.")
    else:
        print(f"Upload failed: {r_up.text}")
else:
    print(f"File not found: {apk_path}")
PY
}

ensure_single_subcontainer_ready() {
  local subdir=$1 repo_name=$2 visibility=$3 remote_url

  if [[ ! -d "$subdir" ]]; then
    echo "Skipping '$subdir' because it no longer exists locally." >&2
    return
  fi

  ensure_remote_repo_exists "$repo_name" "$visibility"
  remote_url=$(resolve_remote_url "$repo_name")

  ensure_submodule_repo_initialized "$subdir"
  ensure_submodule_branch "$subdir"
  ensure_submodule_remote "$subdir" "$remote_url"
  commit_and_push_submodule "$subdir"
  record_subcontainer_commit "$subdir"
  register_submodule_reference "$subdir" "$remote_url"
}

ensure_submodule_repo_initialized() {
  local subdir=$1
  if [[ -e "$subdir/.git" ]]; then
    return
  fi
  git -C "$subdir" init >/dev/null
}

ensure_submodule_branch() {
  local subdir=$1 current
  current=$(git -C "$subdir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  if [[ -z "$current" || "$current" == "HEAD" ]]; then
    git -C "$subdir" symbolic-ref HEAD refs/heads/main >/dev/null 2>&1 || git -C "$subdir" branch -M main
    current="main"
  elif [[ "$current" != "main" ]]; then
    git -C "$subdir" branch -M "$current" main >/dev/null 2>&1 || git -C "$subdir" switch -C main >/dev/null 2>&1
    current="main"
  fi
}

ensure_submodule_remote() {
  local subdir=$1 remote_url=$2 current_remote
  if current_remote=$(git -C "$subdir" remote get-url origin 2>/dev/null); then
    if [[ "$current_remote" != "$remote_url" ]]; then
      git -C "$subdir" remote set-url origin "$remote_url"
    fi
  else
    git -C "$subdir" remote add origin "$remote_url"
  fi
}

stage_submodule_changes() {
  local subdir=$1
  (
    cd "$subdir" || return
    ensure_token_gitignore
    cleanup_local_backup_artifacts
    
    # --- NEW: Auto-ignore problematic files for submodules ---
    # We call the function from the parent script context, but we are inside the subdir subshell
    # so we pass "." as the path.
    auto_ignore_problematic_files "."
    # ---------------------------------------------------------

    remove_paths_from_index "${DEFAULT_INDEX_EXCLUDES[@]}"
    git add --all
    remove_paths_from_index "${DEFAULT_INDEX_EXCLUDES[@]}"
    purge_sensitive_paths_from_index "."
    if [[ "$(basename "$subdir")" != "send_folder_to_github" ]]; then
      protect_path "create_and_push_repo.sh"
      remove_tracked_path "create_and_push_repo.sh"
    fi
    protect_path "GITHUB_TOKEN"
    protect_path "GITHUB_TOKEN.txt"
    protect_path "AMO_API_KEY.txt"
    protect_path "AMO_API_SECRET.txt"
  )
}

commit_and_push_submodule() {
  local subdir=$1
  stage_submodule_changes "$subdir"
  ensure_lfs_for_large_files "$subdir"
  if git -C "$subdir" diff --staged --quiet; then
    : 
  else
    commit_submodule_safely "$subdir"
  fi
  ensure_submodule_initial_commit "$subdir"

  # Sync before push to avoid non-fast-forward errors
  if git -C "$subdir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
      # Only pull if remote is configured
      run_git_pull_command_submodule "$subdir" "main" >/dev/null 2>&1 || true
  fi

  push_submodule_with_credentials "$subdir"
}

commit_submodule_safely() {
  local subdir=$1 has_upstream=1
  if ! git -C "$subdir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    has_upstream=0
  fi

  if git -C "$subdir" rev-parse --verify HEAD >/dev/null 2>&1 && [[ $has_upstream -eq 0 ]]; then
    git -C "$subdir" commit --amend --no-edit
  else
    git -C "$subdir" commit -m "push"
  fi
}

ensure_submodule_initial_commit() {
  local subdir=$1
  if git -C "$subdir" rev-parse --verify HEAD >/dev/null 2>&1; then
    return
  fi
  git -C "$subdir" commit --allow-empty -m "Initial subcontainer commit" >/dev/null
}

run_git_pull_command_submodule() {
  local subdir=$1 branch=$2 output status
  if [[ "${GITHUB_REMOTE_PROTOCOL:-https}" == "https" ]]; then
    output=$(run_with_https_credentials git -C "$subdir" pull --rebase origin "$branch" 2>&1)
  else
    output=$(git -C "$subdir" pull --rebase origin "$branch" 2>&1)
  fi
  status=$?
  printf "%s\n" "$output"
  return $status
}

record_subcontainer_commit() {
  local subdir=$1 commit
  commit=$(git -C "$subdir" rev-parse HEAD 2>/dev/null || true)
  if [[ -n "$commit" ]]; then
    __SUBCONTAINER_COMMITS["$subdir"]="$commit"
  else
    unset "__SUBCONTAINER_COMMITS[$subdir]"
  fi
}

push_submodule_with_credentials() {
  local subdir=$1 branch=${2:-main} output status
  
  # Define push command execution
  local -a push_cmd=(git -C "$subdir" push -u origin "$branch")

  if [[ "${GITHUB_REMOTE_PROTOCOL:-https}" == "https" ]]; then
    output=$(run_with_https_credentials "${push_cmd[@]}" 2>&1)
  else
    output=$("${push_cmd[@]}" 2>&1)
  fi
  status=$?
  
  printf "%s\n" "$output"
  
  # Handle non-fast-forward (fetch first)
  if [[ $status -ne 0 ]] && [[ "$output" == *"fetch first"* || "$output" == *"non-fast-forward"* ]]; then
     echo "Submodule push rejected (non-fast-forward)." >&2
     if [[ "${ALLOW_PULL:-0}" == "1" ]]; then
       echo "ALLOW_PULL=1: attempting pull --rebase for '$subdir' then retrying push..." >&2
       if run_git_pull_command_submodule "$subdir" "$branch"; then
          echo "Pull successful. Retrying push..." >&2
          if [[ "${GITHUB_REMOTE_PROTOCOL:-https}" == "https" ]]; then
              output=$(run_with_https_credentials "${push_cmd[@]}" 2>&1)
          else
              output=$("${push_cmd[@]}" 2>&1)
          fi
          status=$?
          printf "%s\n" "$output"
       fi
     else
       echo "Skipping automatic pull for submodule (ALLOW_PULL=0). Please pull/rebase manually or rerun with ALLOW_PULL=1." >&2
     fi
  fi

  if [[ $status -ne 0 ]]; then
    if handle_large_file_push_rejection "$subdir" "$output"; then
      echo "Retrying submodule push for '$subdir' after enabling Git LFS..." >&2
      push_submodule_with_credentials "$subdir" "$branch"
      return $?
    fi
  fi
  return $status
}

handle_large_file_push_rejection() {
  local repo_path=$1 push_output=$2
  local -a files=()
  mapfile -t files < <(extract_large_file_paths "$push_output")
  if [[ ${#files[@]} -eq 0 ]]; then
    return 1
  fi
  echo "Push rejected: files exceed GitHub's 100 MB limit. Configuring Git LFS for: ${files[*]}" >&2
  apply_lfs_tracking_for_paths "$repo_path" "${files[@]}"
  if amend_last_commit_with_lfs "$repo_path"; then
    return 0
  fi
  return 1
}

apply_lfs_tracking_for_paths() {
  local repo_path=$1
  shift
  if [[ $# -eq 0 ]]; then
    return
  fi
  git -C "$repo_path" lfs install >/dev/null 2>&1 || true
  local file
  declare -A seen=()
  local -a unique=()
  for file in "$@"; do
    [[ -z "$file" ]] && continue
    if [[ -n "${seen[$file]+_}" ]]; then
      continue
    fi
    seen["$file"]=1
    unique+=("$file")
  done
  for file in "${unique[@]}"; do
    git -C "$repo_path" lfs track -- "$file" >/dev/null 2>&1 || true
  done
  git -C "$repo_path" add .gitattributes >/dev/null 2>&1 || true
  git -C "$repo_path" add -- "${unique[@]}" >/dev/null 2>&1 || true
}

amend_last_commit_with_lfs() {
  local repo_path=$1
  if ! git -C "$repo_path" rev-parse HEAD >/dev/null 2>&1; then
    return 1
  fi
  if git -C "$repo_path" diff --cached --quiet; then
    return 1
  fi
  git -C "$repo_path" commit --amend --no-edit >/dev/null 2>&1 || return 1
  return 0
}

extract_large_file_paths() {
  python3 - "$1" <<'PY'
import sys
import re
text = sys.argv[1]
patterns = [
    re.compile(r'File (.+?) is .*?exceeds GitHub', re.IGNORECASE),
    re.compile(r'File (.+?) exceeds GitHub', re.IGNORECASE),
]
found = []
for line in text.splitlines():
    for pat in patterns:
        m = pat.search(line)
        if m:
            path = m.group(1).strip()
            if path and path not in found:
                found.append(path)
            break
print("\n".join(found))
PY
}

register_submodule_reference() {
  local subdir=$1 remote_url=$2
  git config -f .gitmodules "submodule.$subdir.path" "$subdir"
  git config -f .gitmodules "submodule.$subdir.url" "$remote_url"
  git config "submodule.$subdir.path" "$subdir"
  git config "submodule.$subdir.url" "$remote_url"
  git config "submodule.$subdir.update" "checkout"
  git submodule absorbgitdirs "$subdir" >/dev/null 2>&1 || true
}

remove_submodule_config() {
  local subdir=$1
  git config -f .gitmodules --remove-section "submodule.$subdir" >/dev/null 2>&1 || true
  git config --remove-section "submodule.$subdir" >/dev/null 2>&1 || true
  if [[ -d ".git/modules/$subdir" ]]; then
    rm -rf ".git/modules/$subdir"
  fi
}

clear_removed_subcontainers() {
  if [[ ${#__SUBCONTAINERS_TO_CLEAR[@]} -eq 0 ]]; then
    return
  fi
  local entry subdir repo
  for entry in "${__SUBCONTAINERS_TO_CLEAR[@]}"; do
    IFS="|" read -r subdir repo <<<"$entry"
    clear_subcontainer_repo "$repo" "$subdir"
  done
}

format_subcontainer_repo_name() {
  local _root_repo=$1 subdir=$2 segment
  segment=$(sanitize_repo_segment "$subdir")
  printf "%s" "$segment"
}

sanitize_repo_segment() {
  local value=$1
  value=${value//\//-}
  value=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')
  value=${value//[^a-z0-9_-]/-}
  while [[ "$value" == *--* ]]; do
    value=${value//--/-}
  done
  while [[ "$value" == *__* ]]; do
    value=${value//__/_}
  done
  value=${value##-}
  value=${value%%-}
  value=${value##_}
  value=${value%%_}
  if [[ -z "$value" ]]; then
    value="subfolder"
  fi
  printf "%s" "$value"
}

push_commit_to_remote() {
  local remote_url=$1 refspec=$2 force_flag=${3:-} output status
  local -a args=("git" "push")
  if [[ -n "$force_flag" ]]; then
    args+=("$force_flag")
  fi
  args+=("$remote_url" "$refspec")
  if [[ "${GITHUB_REMOTE_PROTOCOL:-https}" == "https" ]]; then
    output=$(run_with_https_credentials "${args[@]}" 2>&1)
  else
    output=$("${args[@]}" 2>&1)
  fi
  status=$?
  printf "%s\n" "$output"
  return $status
}

fetch_remote_head_into_ref() {
  local remote_url=$1 target_ref=$2 output status
  output=$(run_git_with_credentials git fetch --no-tags "$remote_url" "refs/heads/main:$target_ref" 2>&1)
  status=$?
  if [[ $status -ne 0 ]]; then
    printf "%s\n" "$output"
    return $status
  fi
  return 0
}

clear_subcontainer_repo() {
  local repo_name=$1 subdir=$2 remote_url tmp_ref parent empty_tree empty_commit fetch_output
  remote_url=$(resolve_remote_url "$repo_name")
  echo "Clearing subcontainer for removed folder '$subdir' (repo '$repo_name')." >&2
  tmp_ref="refs/tmp/subcontainer-${RANDOM}-${RANDOM}"
  parent=""
  if fetch_output=$(fetch_remote_head_into_ref "$remote_url" "$tmp_ref"); then
    parent=$(git rev-parse "$tmp_ref" 2>/dev/null || true)
  else
    if [[ "$fetch_output" == *"couldn't find remote ref"* || "$fetch_output" == *"could not find remote ref"* ]]; then
      parent=""
    else
      printf "%s\n" "$fetch_output" >&2
    fi
  fi
  git update-ref -d "$tmp_ref" >/dev/null 2>&1 || true

  empty_tree=$(git hash-object -t tree /dev/null)
  if [[ -n "$parent" ]]; then
    empty_commit=$(git commit-tree "$empty_tree" -p "$parent" -m "Remove folder '$subdir' after deletion")
  else
    empty_commit=$(git commit-tree "$empty_tree" -m "Remove folder '$subdir' after deletion")
  fi

  if push_commit_to_remote "$remote_url" "$empty_commit:refs/heads/main"; then
    echo "Subcontainer '$repo_name' cleared successfully." >&2
  else
    echo "Failed to clear subcontainer '$repo_name'." >&2
  fi
}

remove_paths_from_index() {
  local path
  for path in "$@"; do
    [[ -z "$path" ]] && continue
    git rm -rf --cached --ignore-unmatch -- "$path" >/dev/null 2>&1 || true
  done
}

purge_sensitive_paths_from_index() {
  local repo_path=${1:-.}
  (
    cd "$repo_path" || return 0
    local pattern
    for pattern in "${SENSITIVE_PATHS[@]}"; do
      [[ -z "$pattern" ]] && continue
      # Use find to locate files matching the pattern recursively and remove them from index
      find . -name "$pattern" -exec git rm --cached --ignore-unmatch -- {} + >/dev/null 2>&1 || true
    done
  )
}

stage_files_excluding_script() {
  local script_rel=$1
  ensure_token_gitignore
  cleanup_local_backup_artifacts
  ensure_submodules_populated
  
  # --- NEW: Auto-ignore problematic files before adding ---
  auto_ignore_problematic_files "."
  # --------------------------------------------------------

  remove_paths_from_index "${DEFAULT_INDEX_EXCLUDES[@]}"
  git add --all
  remove_paths_from_index "${DEFAULT_INDEX_EXCLUDES[@]}"
  purge_sensitive_paths_from_index "."
  if [[ "${ROOT_REPO_NAME:-}" != "send_folder_to_github" && -n "$script_rel" ]]; then
    protect_path "$script_rel"
    remove_tracked_path "$script_rel"
  fi
  if [[ "$SUBCONTAINER_MODE" == "true" ]]; then
    enforce_subcontainer_gitlinks
  fi
  ensure_lfs_for_large_files "."
  protect_path "GITHUB_TOKEN"
  protect_path "GITHUB_TOKEN.txt"
  protect_path "AMO_API_KEY.txt"
  protect_path "AMO_API_SECRET.txt"
}

# --- NEW FUNCTION: Auto-detect and ignore sensitive/problematic files ---
auto_ignore_problematic_files() {
  local repo_path=$1
  (
    cd "$repo_path" || return
    local changed=0
    
    # 1. Handle GitHub Workflows (fixes 'refusing to allow... workflow scope' error)
    if [[ -d ".github/workflows" ]]; then
       if ! grep -q "^\.github/workflows/" .gitignore 2>/dev/null; then
           [[ -s .gitignore && "$(tail -c 1 .gitignore | wc -l)" -eq 0 ]] && echo "" >> .gitignore
           echo ".github/workflows/" >> .gitignore
           echo "   [Auto-Fix] Ignored .github/workflows/ to prevent permission errors." >&2
           changed=1
       fi
       # Remove from index if present
       git rm -r --cached --ignore-unmatch .github/workflows/ >/dev/null 2>&1 || true
    fi

    # 2. Handle Sensitive Files (fixes 'Repository rule violations... secrets' error)
    local -a sensitive_patterns=(
        "*key.json"
        "*credential*.json"
        "client_secret*.json"
        "*.pem"
        "*.p12"
        "id_rsa"
        "id_dsa"
        "*.keystore"
        "*.jks"
    )

    local pattern found_files
    for pattern in "${sensitive_patterns[@]}"; do
        # Find files matching pattern (exclude .git)
        found_files=$(find . -maxdepth 4 -name "$pattern" -not -path "./.git/*" 2>/dev/null)
        
        if [[ -n "$found_files" ]]; then
            # Check if pattern is already in gitignore
            if ! grep -Fq "$pattern" .gitignore 2>/dev/null; then
                [[ -s .gitignore && "$(tail -c 1 .gitignore | wc -l)" -eq 0 ]] && echo "" >> .gitignore
                echo "$pattern" >> .gitignore
                echo "   [Auto-Fix] Ignored sensitive pattern '$pattern' found in repo." >&2
                changed=1
            fi
            
            # Remove specific files from index
            for file in $found_files; do
                git rm --cached --ignore-unmatch "$file" >/dev/null 2>&1 || true
            done
        fi
    done
    
    # 3. Handle System Junk & Default Excludes
    local -a all_excludes=("${DEFAULT_INDEX_EXCLUDES[@]}")
    # Add common junk that might not be in the global list
    all_excludes+=("__pycache__" ".DS_Store" "Thumbs.db")

    for item in "${all_excludes[@]}"; do
         # Remove trailing slashes for directory check
         local clean_item=${item%/}
         
         if [[ -e "$clean_item" ]]; then
             if ! grep -Fxq "$clean_item" .gitignore 2>/dev/null && ! grep -Fxq "$clean_item/" .gitignore 2>/dev/null; then
                 [[ -s .gitignore && "$(tail -c 1 .gitignore | wc -l)" -eq 0 ]] && echo "" >> .gitignore
                 # If it's a directory, add trailing slash to gitignore
                 if [[ -d "$clean_item" ]]; then
                    echo "$clean_item/" >> .gitignore
                 else
                    echo "$clean_item" >> .gitignore
                 fi
                 echo "   [Auto-Fix] Ignored excluded item '$clean_item'." >&2
                 changed=1
             fi
             git rm -r --cached --ignore-unmatch "$clean_item" >/dev/null 2>&1 || true
         fi
    done
  )
}
# ------------------------------------------------------------------------

ensure_submodules_populated() {
  if [[ ! -f .gitmodules ]]; then
    return
  fi
  if ! git config -f .gitmodules --get-regexp '^submodule\.' >/dev/null 2>&1; then
    return
  fi
  if run_git_with_credentials git submodule update --init --recursive >/dev/null 2>&1; then
    return
  fi
  echo "Warning: failed to populate existing submodules automatically. Run 'git submodule update --init --recursive' and retry if issues persist." >&2
}

enforce_subcontainer_gitlinks() {
  local entry subdir repo visibility commit
  if [[ ${#__SUBCONTAINERS_TO_PUSH[@]} -eq 0 ]]; then
    return
  fi
  for entry in "${__SUBCONTAINERS_TO_PUSH[@]}"; do
    IFS="|" read -r subdir repo visibility <<<"$entry"
    [[ -d "$subdir" ]] || continue
    commit=${__SUBCONTAINER_COMMITS[$subdir]:-}
    if [[ -z "$commit" ]]; then
      commit=$(git -C "$subdir" rev-parse HEAD 2>/dev/null || true)
    fi
    if [[ -z "$commit" ]]; then
      echo "Warning: subcontainer '$subdir' has no commits to reference; keeping it as a normal folder in this push." >&2
      continue
    fi
    stage_subcontainer_gitlink "$subdir" "$commit"
  done
}

stage_subcontainer_gitlink() {
  local subdir=$1 commit=$2
  git rm -r --cached --ignore-unmatch -- "$subdir" >/dev/null 2>&1 || true
  git update-index --add --cacheinfo 160000 "$commit" "$subdir" >/dev/null
}

ensure_lfs_for_large_files() {
  local repo_path=$1
  local threshold=${GIT_LFS_THRESHOLD_BYTES:-104857600}
  local -a to_track=()
  local path full size attr
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    full="$repo_path/$path"
    [[ ! -f "$full" ]] && continue
    size=$(stat -c%s -- "$full" 2>/dev/null || echo 0)
    if (( size < threshold )); then
      continue
    fi
    attr=$(git -C "$repo_path" check-attr filter -- "$path" 2>/dev/null || true)
    if [[ "$attr" == *"filter: lfs"* ]]; then
      continue
    fi
    to_track+=("$path")
  done < <(git -C "$repo_path" diff --cached --name-only --diff-filter=AM 2>/dev/null || true)

  if [[ ${#to_track[@]} -eq 0 ]]; then
    return
  fi

  git -C "$repo_path" lfs install >/dev/null 2>&1 || true
  local target
  for target in "${to_track[@]}"; do
    git -C "$repo_path" lfs track -- "$target" >/dev/null 2>&1 || true
  done
  git -C "$repo_path" add .gitattributes >/dev/null 2>&1 || true
  git -C "$repo_path" add -- "${to_track[@]}" >/dev/null 2>&1 || true
  echo "Large files routed through Git LFS in '$repo_path': ${to_track[*]}" >&2
}

cleanup_local_backup_artifacts() {
  local -a backups=()
  while IFS= read -r -d '' path; do
    path=${path#./}
    backups+=("$path")
  done < <(find . -path ./.git -prune -o -name "*.local-backup-*" -print0 2>/dev/null || true)

  if [[ ${#backups[@]} -eq 0 ]]; then
    return
  fi

  local path
  for path in "${backups[@]}"; do
    git rm -rf --cached --ignore-unmatch -- "$path" >/dev/null 2>&1 || true
    rm -rf -- "$path"
  done
  echo "Temporary backups removed: ${backups[*]}" >&2
}

ensure_token_gitignore() {
  local gitignore=.gitignore
  local entries=(
    ".env"
    "*.env.local"
    "*.env.development"
    "*.env.production"
    "__pycache__/"
    "pycache"
    ".gemini"
    "GITHUB_TOKEN"
    "GITHUB_TOKEN.txt"
    "AMO_API_KEY.txt"
    "AMO_API_SECRET.txt"
    "gemini-gcloud-key.json"
    "gcp-oauth.keys.json"
    "*API*"
    ".eslintcache/"
    "node_modules/"
    "dist/"
    "build/"
    "*.zip"
  )
  if [[ ! -f $gitignore ]]; then
    printf "%s\n" "${entries[@]}" > "$gitignore"
    return
  fi

  # Ensure the file ends with a newline before appending
  if [[ -s "$gitignore" && "$(tail -c 1 "$gitignore" | wc -l)" -eq 0 ]]; then
      echo "" >> "$gitignore"
  fi

  local entry
  for entry in "${entries[@]}"; do
    if ! grep -Fxq "$entry" "$gitignore"; then
      printf "%s\n" "$entry" >> "$gitignore"
    fi
  
  done
}

protect_path() {
  local path=$1
  [[ -z "$path" ]] && return
  git restore --staged -- "$path" >/dev/null 2>&1 || git reset HEAD -- "$path" >/dev/null 2>&1 || true
  if git ls-files --error-unmatch "$path" >/dev/null 2>&1; then
    return
  fi
  git rm --cached -- "$path" >/dev/null 2>&1 || true
}

remove_tracked_path() {
  local path=$1
  [[ -z "$path" ]] && return
  git rm --cached --ignore-unmatch -- "$path" >/dev/null 2>&1 || true
}

commit_changes() {
  if git diff --staged --quiet; then
    return 1
  fi
  git commit -m "push"
  return 0
}

# Credentials helpers --------------------------------------------------------
run_with_https_credentials() {
  local askpass status
  askpass=$(mktemp)
  cat >"$askpass" <<'ASKPASS'
#!/usr/bin/env bash
if [[ "$1" == *Username* ]]; then
  printf '%s\n' "luascfl"
else
  printf '%s\n' "${GITHUB_TOKEN}"
fi
ASKPASS
  chmod +x "$askpass"
  GIT_TERMINAL_PROMPT=0 GIT_ASKPASS="$askpass" "$@"
  status=$?
  rm -f "$askpass"
  return $status
}

run_git_with_credentials() {
  if [[ "${GITHUB_REMOTE_PROTOCOL:-https}" == "https" ]]; then
    run_with_https_credentials "$@"
  else
    "$@"
  fi
}

push_with_credentials() {
  local branch=$1 output status
  if [[ "${GITHUB_REMOTE_PROTOCOL:-https}" == "https" ]]; then
    if output=$(run_with_https_credentials git push -u origin "$branch" 2>&1); then
      status=0
    else
      status=$?
    fi
  else
    if output=$(git push -u origin "$branch" 2>&1); then
      status=0
    else
      status=$?
    fi
  fi
  printf "%s\n" "$output"
  if [[ $status -ne 0 && "$output" =~ non-fast-forward ]]; then
    echo "Push rejected (non-fast-forward)." >&2
    if [[ "${ALLOW_PULL:-0}" == "1" ]]; then
      echo "ALLOW_PULL=1: attempting pull --rebase then retrying push..." >&2
      if pull_with_credentials "$branch" && push_with_credentials "$branch"; then
        return 0
      fi
    else
      echo "Skipping automatic pull (ALLOW_PULL=0). Please pull/rebase manually or rerun with ALLOW_PULL=1." >&2
      return $status
    fi
  fi
  if [[ $status -ne 0 ]]; then
    if handle_large_file_push_rejection "." "$output"; then
      echo "Retrying push after enabling Git LFS for large files..." >&2
      push_with_credentials "$branch"
      return $?
    fi
  fi
  return $status
}

# Pull / rebase --------------------------------------------------------------
pull_with_credentials() {
  local branch=$1 output
  if output=$(run_git_pull_command "$branch"); then
    printf "%s\n" "$output"
    return 0
  fi

  printf "%s\n" "$output" >&2
  echo "Warning: 'pull --rebase' failed. Working tree left untouched; resolve conflicts/stash/clean manually." >&2
  return 1
}

run_git_pull_command() {
  local branch=$1 output status
  if [[ "${GITHUB_REMOTE_PROTOCOL:-https}" == "https" ]]; then
    output=$(run_with_https_credentials git pull --rebase origin "$branch" 2>&1)
  else
    output=$(git pull --rebase origin "$branch" 2>&1)
  fi
  status=$?
  printf "%s" "$output"
  return $status
}

is_untracked_overwrite_error() {
  grep -q "untracked working tree files would be overwritten" <<<"$1"
}

resolve_untracked_overwrite_conflicts() {
  local branch=$1 message=$2 path backup timestamp
  timestamp=$(date +%s)

  while read -r path; do
    [[ -z "$path" ]] && continue
    [[ ! -e "$path" ]] && continue

    backup="${path}.local-backup-${timestamp}"
    while [[ -e "$backup" ]]; do
      backup="${backup}-${RANDOM}"
    done

    cp -a -- "$path" "$backup"
    rm -rf -- "$path"
    __register_backup "$path" "$backup"
    echo "Local file '$path' was temporarily saved in '$backup' to allow pull to continue." >&2
  done < <(extract_untracked_conflict_paths "$message")

  local retry
  if retry=$(run_git_pull_command "$branch"); then
    printf "%s\n" "$retry"
    return 0
  fi

  printf "%s\n" "$retry" >&2
  return 1
}

extract_untracked_conflict_paths() {
  awk '
    /untracked working tree files would be overwritten by checkout:/ {collect=1; next}
    /Please move or remove them before you switch branches/ {collect=0}
    collect && NF { gsub(/^[[:space:]]+/, "", $0); print }
  ' <<<"$1"
}

__register_backup() {
  __UNTRACKED_BACKUPS+=("$1|$2")
}

__restore_all_backups() {
  local entry original backup
  if [[ ${#__UNTRACKED_BACKUPS[@]} -eq 0 ]]; then
    return
  fi

  for entry in "${__UNTRACKED_BACKUPS[@]}"; do
    original=${entry%%|*}
    backup=${entry#*|}
    [[ -z "$original" || -z "$backup" ]] && continue
    if [[ -e "$backup" ]]; then
      rm -rf -- "$original"
      mv -- "$backup" "$original"
      echo "Restored local version: $original" >&2
    fi
  done
  __UNTRACKED_BACKUPS=()
}

rebase_in_progress() {
  [[ -d .git/rebase-apply || -d .git/rebase-merge ]]
}

auto_resolve_rebase_conflicts() {
  local branch=$1
  local -a conflicts
  mapfile -t conflicts < <(git diff --name-only --diff-filter=U)

  if [[ ${#conflicts[@]} -eq 0 ]]; then
    abort_rebase_with_warning "Rebase in progress, but no conflicted files were detected automatically."
    return 1
  fi

  local file
  for file in "${conflicts[@]}"; do
    if ! resolve_conflict_for_file "$file"; then
      abort_rebase_with_warning "Conflict in '$file' requires manual resolution."
      return 1
    fi
  done

  if git rebase --continue >/tmp/rebase-continue.log 2>&1; then
    cat /tmp/rebase-continue.log
    rm -f /tmp/rebase-continue.log
    return 0
  fi

  abort_rebase_with_warning "Unable to complete the rebase automatically."
  return 1
}

resolve_conflict_for_file() {
  local file=$1
  case "$file" in
    .gitignore)
      git checkout --theirs -- .gitignore >/dev/null 2>&1 || return 1
      ensure_token_gitignore
      git add .gitignore
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

abort_rebase_with_warning() {
  local message=$1
  local status_output
  status_output=$(git status --short 2>/dev/null || true)
  git rebase --abort >/dev/null 2>&1 || true
  echo "$message" >&2
  if [[ -n "$status_output" ]]; then
    echo "Files in conflict:" >&2
    echo "$status_output" >&2
  fi
}

main "$@"
