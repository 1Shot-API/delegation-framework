#!/usr/bin/env bash
# verify-arc-broadcast.sh
#
# Verifies Arc mainnet (5042) contracts listed in deployments/arc-5042-manifest.json
# (sourced from broadcast/*/5042/run-latest.json). LiFiSwapEnforcer v3 trio is excluded
# from the manifest (verify separately).
#
# Usage (from repo root):
#   source .env
#   ./script/verification/verify-arc-broadcast.sh
#
# Optional: SOURCIFY_FALLBACK=1 to retry failures via Blockscout verify_via_sourcify.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MANIFEST="${REPO_ROOT}/deployments/arc-5042-manifest.json"

set -o allexport
# shellcheck source=/dev/null
source "${REPO_ROOT}/.env"
set +o allexport

export VERIFY_CHAIN_IDS="5042"
export VERIFY_SKIP_WATCH="1"

# shellcheck source=verify-utils.sh
source "${SCRIPT_DIR}/verify-utils.sh"

HYBRID_LIB="lib/SCL/src/lib/libSCL_RIP7212.sol:SCL_RIP7212:0xCCD3B747F3DBd349fa3af4eBC7d0C31aE6f21dd1"

VERIFY_ORDER=(
  SCL_RIP7212
  DelegationManager
  MultiSigDeleGator
  EIP7702StatelessDeleGator
  HybridDeleGator
)

declare -a FAILURES=()

contract_path_for() {
  local name="$1"
  case "$name" in
    SCL_RIP7212) echo "lib/SCL/src/lib/libSCL_RIP7212.sol" ;;
    DelegationManager) echo "src/DelegationManager.sol" ;;
    MultiSigDeleGator) echo "src/MultiSigDeleGator.sol" ;;
    HybridDeleGator) echo "src/HybridDeleGator.sol" ;;
    EIP7702StatelessDeleGator) echo "src/EIP7702/EIP7702StatelessDeleGator.sol" ;;
    SimpleFactory) echo "src/utils/SimpleFactory.sol" ;;
    ERC1967Proxy) echo "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol" ;;
    *) echo "src/enforcers/${name}.sol" ;;
  esac
}

encode_constructor_args() {
  local name="$1"
  local args_json="$2"
  if [[ "$args_json" == "null" || -z "$args_json" ]]; then
    echo ""
    return 0
  fi
  case "$name" in
    DelegationManager)
      cast abi-encode "constructor(address)" "$(jq -r '.[0]' <<<"$args_json")"
      ;;
    MultiSigDeleGator | HybridDeleGator | EIP7702StatelessDeleGator)
      cast abi-encode "constructor(address,address)" "$(jq -r '.[0]' <<<"$args_json")" "$(jq -r '.[1]' <<<"$args_json")"
      ;;
    LogicalOrWrapperEnforcer)
      cast abi-encode "constructor(address)" "$(jq -r '.[0]' <<<"$args_json")"
      ;;
    NativeTokenPaymentEnforcer)
      cast abi-encode "constructor(address,address)" "$(jq -r '.[0]' <<<"$args_json")" "$(jq -r '.[1]' <<<"$args_json")"
      ;;
    ERC1967Proxy)
      cast abi-encode "constructor(address,bytes)" "$(jq -r '.[0]' <<<"$args_json")" "$(jq -r '.[1]' <<<"$args_json")"
      ;;
    *)
      echo "Unknown constructor shape for $name" >&2
      return 1
      ;;
  esac
}

library_string_for() {
  local name="$1"
  if [[ "$name" == "HybridDeleGator" ]]; then
    echo "$HYBRID_LIB"
  else
    echo ""
  fi
}

blockscout_is_verified() {
  local address="$1"
  local resp
  resp="$(curl -sS "https://api.blockscout.com/5042/api/v2/smart-contracts/${address}?apikey=${BLOCKSCOUT_API_KEY}")"
  jq -e '.is_verified == true' <<<"$resp" >/dev/null 2>&1
}

sourcify_fallback() {
  local address="$1"
  curl -sS -X POST \
    "https://api.blockscout.com/v2/api?chain_id=5042&module=contract&action=verify_via_sourcify&apikey=${BLOCKSCOUT_API_KEY}" \
    --form "addressHash=${address}" | jq -r '.message // .error // .'
}

verify_one() {
  local name="$1"
  local address="$2"
  local args_json="$3"

  if blockscout_is_verified "$address"; then
    echo "SKIP (already verified): $name at $address"
    return 0
  fi

  local path
  path="$(contract_path_for "$name")"
  local ctor=""
  local lib=""

  if [[ "$args_json" != "null" && -n "$args_json" ]]; then
    ctor="$(encode_constructor_args "$name" "$args_json")"
  fi
  lib="$(library_string_for "$name")"

  echo "-------------------------------------------"
  echo "Verifying: $name at $address"
  echo "-------------------------------------------"

  if verify_across_chains "$path" "$name" "$address" "$ctor" "$lib"; then
    return 0
  fi

  if [[ "${SOURCIFY_FALLBACK:-}" != "1" ]]; then
    FAILURES+=("$name:$address")
    return 1
  fi

  if [[ "${SOURCIFY_FALLBACK:-}" == "1" ]] && ! blockscout_is_verified "$address"; then
    echo "Forge failed; trying Sourcify + Blockscout verify_via_sourcify for $address ..."
    local ctor_flag=()
    if [[ -n "$ctor" ]]; then
      ctor_flag=(--constructor-args "$ctor")
    fi
    local lib_flag=()
    if [[ -n "$lib" ]]; then
      lib_flag=(--libraries "$lib")
    fi
    forge verify-contract --num-of-optimizations 200 --chain-id 5042 --verifier sourcify \
      --verifier-url https://sourcify.dev/server "${ctor_flag[@]}" "${lib_flag[@]}" \
      "$address" "${path}:${name}" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6; do
      sourcify_fallback "$address"
      sleep 10
      if blockscout_is_verified "$address"; then
        return 0
      fi
    done
  fi

  FAILURES+=("$name:$address")
  return 1
}

verify_erc1967_proxy_link() {
  local proxy="$1"
  echo "Linking ERC1967Proxy via verifyproxycontract ..."
  local guid
  guid="$(curl -sS \
    "https://api.blockscout.com/v2/api?chain_id=5042&module=contract&action=verifyproxycontract&address=${proxy}&apikey=${BLOCKSCOUT_API_KEY}" \
    | jq -r '.result // empty')"
  if [[ -z "$guid" ]]; then
    echo "WARN: no guid from verifyproxycontract" >&2
    return 0
  fi
  for _ in 1 2 3 4 5; do
    local status
    status="$(curl -sS \
      "https://api.blockscout.com/v2/api?chain_id=5042&module=contract&action=checkproxyverification&guid=${guid}&apikey=${BLOCKSCOUT_API_KEY}" \
      | jq -r '.result // empty')"
    echo "$status"
    if [[ "$status" == *"successfully updated"* ]] || [[ "$status" == *"found at"* ]]; then
      return 0
    fi
    sleep 3
  done
}

manifest_entry() {
  local name="$1"
  jq -c --arg n "$name" '.[] | select(.name == $n)' "$MANIFEST" | head -1
}

if [[ ! -f "$MANIFEST" ]]; then
  echo "Missing manifest: $MANIFEST" >&2
  exit 1
fi

cd "$REPO_ROOT"

for name in "${VERIFY_ORDER[@]}"; do
  entry="$(manifest_entry "$name")"
  if [[ -z "$entry" ]]; then
    continue
  fi
  address="$(jq -r '.address' <<<"$entry")"
  args_json="$(jq -c '.args' <<<"$entry")"
  verify_one "$name" "$address" "$args_json" || true
done

while IFS= read -r entry; do
  name="$(jq -r '.name' <<<"$entry")"
  skip=0
  for ordered in "${VERIFY_ORDER[@]}"; do
    if [[ "$ordered" == "$name" ]]; then
      skip=1
      break
    fi
  done
  if [[ "$skip" -eq 1 ]]; then
    continue
  fi
  if [[ "$name" == "LogicalOrWrapperEnforcer" || "$name" == "NativeTokenPaymentEnforcer" ]]; then
    continue
  fi
  address="$(jq -r '.address' <<<"$entry")"
  args_json="$(jq -c '.args' <<<"$entry")"
  verify_one "$name" "$address" "$args_json" || true
done < <(jq -c '.[]' "$MANIFEST")

for name in LogicalOrWrapperEnforcer NativeTokenPaymentEnforcer; do
  entry="$(manifest_entry "$name")"
  if [[ -n "$entry" ]]; then
    address="$(jq -r '.address' <<<"$entry")"
    args_json="$(jq -c '.args' <<<"$entry")"
    verify_one "$name" "$address" "$args_json" || true
  fi
done

for name in SimpleFactory ERC1967Proxy; do
  entry="$(manifest_entry "$name")"
  if [[ -n "$entry" ]]; then
    address="$(jq -r '.address' <<<"$entry")"
    args_json="$(jq -c '.args' <<<"$entry")"
    verify_one "$name" "$address" "$args_json" || true
  fi
done

proxy_entry="$(manifest_entry "ERC1967Proxy")"
if [[ -n "$proxy_entry" ]]; then
  verify_erc1967_proxy_link "$(jq -r '.address' <<<"$proxy_entry")" || true
fi

if [[ ${#FAILURES[@]} -gt 0 ]]; then
  echo "FAILED verifications:"
  printf '  %s\n' "${FAILURES[@]}"
  exit 1
fi

echo "All Arc broadcast contracts verified (or already verified)."
