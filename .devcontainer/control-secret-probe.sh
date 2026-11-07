#!/usr/bin/env bash
set -euo pipefail
set +x

secret_name="${1:?secret name required}"
if ! [[ "$secret_name" =~ ^[A-Z0-9_]+$ ]]; then
  exit 2
fi

if test -z "${!secret_name-}" && test -r /workspaces/.codespaces/shared/.env; then
  set -a
  # shellcheck disable=SC1091
  . /workspaces/.codespaces/shared/.env
  set +a
fi

secret_value="${!secret_name-}"
secret_present=false
secret_sha256=""
if test -n "$secret_value"; then
  secret_present=true
  secret_sha256="$(printf %s "$secret_value" | sha256sum | cut -d ' ' -f1)"
fi
unset secret_value GH_TOKEN GITHUB_TOKEN

jq -n \
  --argjson automatic_postcreate "${CODEX_REF_CONTROL_AUTOMATIC:-false}" \
  --argjson secret_present "$secret_present" \
  --arg secret_sha256 "$secret_sha256" \
  --arg repository_environment "${GITHUB_REPOSITORY-}" \
  --arg codespace_name "${CODESPACE_NAME-}" \
  '{automatic_postcreate:$automatic_postcreate,secret_present:$secret_present,secret_sha256:$secret_sha256,repository_environment:$repository_environment,codespace_name:$codespace_name}'
