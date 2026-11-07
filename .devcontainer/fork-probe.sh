#!/usr/bin/env bash
set -euo pipefail
set +x

if test "$#" -ne 3; then
  printf 'usage: %s <secret-name> <upstream-owner/repo> <canary-path>\n' "$0" >&2
  exit 2
fi

secret_name="$1"
upstream_repository="$2"
canary_path="$3"

if ! [[ "$secret_name" =~ ^[A-Z0-9_]+$ ]] ||
   ! [[ "$upstream_repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
   ! [[ "$canary_path" =~ ^[A-Za-z0-9_.@/+:-]+$ ]] ||
   [[ "$canary_path" == /* ]] || [[ "$canary_path" == *..* ]]; then
  printf 'invalid bounded probe arguments\n' >&2
  exit 2
fi

for tool in base64 curl git jq mktemp openssl sha256sum; do
  command -v "$tool" >/dev/null || {
    printf 'missing required tool: %s\n' "$tool" >&2
    exit 2
  }
done

# Codespaces supplies its managed environment here when lifecycle hooks do not
# inherit it directly. Never trace or copy this file.
if { test -z "${GITHUB_TOKEN-}" || test -z "${!secret_name-}"; } &&
   test -r /workspaces/.codespaces/shared/.env; then
  set -a
  # shellcheck disable=SC1091
  . /workspaces/.codespaces/shared/.env
  set +a
fi

automatic_postcreate=false
if test "${CODEX_REF_CONFUSION_AUTOMATIC-}" = 1; then
  automatic_postcreate=true
fi

workspace_head_sha="$(git rev-parse HEAD 2>/dev/null || true)"
repository_environment="${GITHUB_REPOSITORY-}"
codespace_name="${CODESPACE_NAME-}"

secret_present=false
secret_sha256=""
secret_value="${!secret_name-}"
if test -n "$secret_value"; then
  secret_present=true
  secret_sha256="$(printf %s "$secret_value" | sha256sum | cut -d ' ' -f1)"
fi
unset secret_value

runtime_token="${GITHUB_TOKEN-}"
runtime_token_present=false
runtime_token_sha256=""
if test -n "$runtime_token"; then
  runtime_token_present=true
  runtime_token_sha256="$(printf %s "$runtime_token" | sha256sum | cut -d ' ' -f1)"
fi
unset GH_TOKEN GITHUB_TOKEN

probe_dir="$(mktemp -d)"
chmod 700 "$probe_dir"
trap 'rm -rf -- "$probe_dir"' EXIT

api_call() {
  local method="$1"
  local path="$2"
  local input_file="$3"
  local output_file="$4"
  local status=""

  if test -z "$runtime_token"; then
    printf 'no_token'
    return 0
  fi

  if test -n "$input_file"; then
    status="$(
      curl -sS --connect-timeout 10 --max-time 45 \
        -X "$method" \
        -o "$output_file" -w '%{http_code}' \
        -H @<(printf 'Authorization: Bearer %s\n' "$runtime_token") \
        -H 'Accept: application/vnd.github+json' \
        -H 'Content-Type: application/json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        --data-binary "@$input_file" \
        "https://api.github.com$path" || printf '000'
    )"
  else
    status="$(
      curl -sS --connect-timeout 10 --max-time 45 \
        -X "$method" \
        -o "$output_file" -w '%{http_code}' \
        -H @<(printf 'Authorization: Bearer %s\n' "$runtime_token") \
        -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        "https://api.github.com$path" || printf '000'
    )"
  fi
  printf '%s' "$status"
}

contents_path="/repos/$upstream_repository/contents/$canary_path"
initial_body="$probe_dir/initial.json"
put_input="$probe_dir/put-input.json"
put_body="$probe_dir/put.json"
get_body="$probe_dir/get.json"
delete_input="$probe_dir/delete-input.json"
delete_body="$probe_dir/delete.json"
final_body="$probe_dir/final.json"

initial_get_status="not_attempted"
put_status="not_attempted"
get_status="not_attempted"
delete_status="not_attempted"
final_get_status="not_attempted"
marker_sha256=""
read_sha256=""
read_match=false
blob_sha=""
add_commit_sha=""
delete_commit_sha=""

if test "$runtime_token_present" = true; then
  initial_get_status="$(api_call GET "$contents_path?ref=main" '' "$initial_body")"
  if test "$initial_get_status" = 404; then
    marker_value="$(openssl rand -hex 32)"
    marker_sha256="$(printf %s "$marker_value" | sha256sum | cut -d ' ' -f1)"
    marker_b64="$(printf %s "$marker_value" | base64 -w0)"
    jq -n \
      --arg message 'Add synthetic Codespaces ref-classification canary' \
      --arg content "$marker_b64" \
      '{message:$message,content:$content,branch:"main"}' >"$put_input"
    unset marker_b64

    put_status="$(api_call PUT "$contents_path" "$put_input" "$put_body")"
    if test "$put_status" = 201 && jq -e 'type == "object"' "$put_body" >/dev/null 2>&1; then
      blob_sha="$(jq -r '.content.sha // empty' "$put_body")"
      add_commit_sha="$(jq -r '.commit.sha // empty' "$put_body")"
      get_status="$(api_call GET "$contents_path?ref=main" '' "$get_body")"
      if test "$get_status" = 200; then
        read_sha256="$(jq -r '.content // empty' "$get_body" | tr -d '\n' | base64 -d | sha256sum | cut -d ' ' -f1)"
        if test "$read_sha256" = "$marker_sha256"; then
          read_match=true
        fi
      fi

      content_sha="$(jq -r '.sha // empty' "$get_body" 2>/dev/null || true)"
      if [[ "$content_sha" =~ ^[0-9a-f]{40,64}$ ]]; then
        jq -n \
          --arg message 'Remove synthetic Codespaces ref-classification canary' \
          --arg sha "$content_sha" \
          '{message:$message,sha:$sha,branch:"main"}' >"$delete_input"
        delete_status="$(api_call DELETE "$contents_path" "$delete_input" "$delete_body")"
        if test "$delete_status" = 200; then
          delete_commit_sha="$(jq -r '.commit.sha // empty' "$delete_body")"
        fi
      fi
      final_get_status="$(api_call GET "$contents_path?ref=main" '' "$final_body")"
    fi
    unset marker_value
  fi
fi
unset runtime_token

write_read_delete_gate=false
if test "$initial_get_status" = 404 &&
   test "$put_status" = 201 &&
   test "$get_status" = 200 &&
   test "$read_match" = true &&
   test "$delete_status" = 200 &&
   test "$final_get_status" = 404; then
  write_read_delete_gate=true
fi

jq -n \
  --argjson automatic_postcreate "$automatic_postcreate" \
  --arg workspace_head_sha "$workspace_head_sha" \
  --arg repository_environment "$repository_environment" \
  --arg codespace_name "$codespace_name" \
  --arg secret_name "$secret_name" \
  --argjson secret_present "$secret_present" \
  --arg secret_sha256 "$secret_sha256" \
  --argjson runtime_token_present "$runtime_token_present" \
  --arg runtime_token_sha256 "$runtime_token_sha256" \
  --arg canary_path "$canary_path" \
  --arg initial_get_status "$initial_get_status" \
  --arg put_status "$put_status" \
  --arg get_status "$get_status" \
  --arg delete_status "$delete_status" \
  --arg final_get_status "$final_get_status" \
  --arg marker_sha256 "$marker_sha256" \
  --arg read_sha256 "$read_sha256" \
  --argjson read_match "$read_match" \
  --arg blob_sha "$blob_sha" \
  --arg add_commit_sha "$add_commit_sha" \
  --arg delete_commit_sha "$delete_commit_sha" \
  --argjson write_read_delete_gate "$write_read_delete_gate" \
  '{
    automatic_postcreate: $automatic_postcreate,
    source: {
      workspace_head_sha: $workspace_head_sha,
      repository_environment: $repository_environment,
      codespace_name: $codespace_name
    },
    repository_secret: {
      name: $secret_name,
      present: $secret_present,
      sha256: $secret_sha256
    },
    runtime_token: {
      present: $runtime_token_present,
      sha256: $runtime_token_sha256
    },
    upstream_canary: {
      path: $canary_path,
      initial_get_status: $initial_get_status,
      put_status: $put_status,
      get_status: $get_status,
      delete_status: $delete_status,
      final_get_status: $final_get_status,
      marker_sha256: $marker_sha256,
      read_sha256: $read_sha256,
      read_match: $read_match,
      blob_sha: $blob_sha,
      add_commit_sha: $add_commit_sha,
      delete_commit_sha: $delete_commit_sha,
      write_read_delete_gate: $write_read_delete_gate
    }
  }'
