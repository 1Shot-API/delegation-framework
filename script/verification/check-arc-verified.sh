#!/usr/bin/env bash
# check-arc-verified.sh — report Blockscout is_verified for deployments/arc-5042-manifest.json
#
# Usage: source .env && ./script/verification/check-arc-verified.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MANIFEST="${REPO_ROOT}/deployments/arc-5042-manifest.json"

set -o allexport
# shellcheck source=/dev/null
source "${REPO_ROOT}/.env"
set +o allexport

if [[ ! -f "$MANIFEST" ]]; then
  echo "Missing manifest: $MANIFEST" >&2
  exit 1
fi

missing=0
while IFS= read -r entry; do
  name="$(jq -r '.name' <<<"$entry")"
  address="$(jq -r '.address' <<<"$entry")"
  resp="$(curl -sS "https://api.blockscout.com/5042/api/v2/smart-contracts/${address}?apikey=${BLOCKSCOUT_API_KEY}")"
  verified="$(jq -r '.is_verified // false' <<<"$resp")"
  if [[ "$verified" == "true" ]]; then
    echo "OK  $name $address"
  else
    echo "NO  $name $address"
    missing=$((missing + 1))
  fi
done < <(jq -c '.[]' "$MANIFEST")

echo "---"
echo "Unverified: $missing"
exit "$missing"
