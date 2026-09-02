# LiFi Swap CLI

Staged CLI for **LiFiSwapEnforcer** delegations on Base mainnet: create a signed delegation, save it locally, then execute swaps repeatedly against the same grant to test periodic budgets.

## Prerequisites

- Node.js 20+ with `npm install`
- Copy [`.env.example`](./.env.example) to `.env` in this directory and set `PRIVATE_KEY`, `BASE_RPC_URL`, and `LIFI_*` variables
- Base ETH for gas (via relayer fee token) and input ERC-20 balance (e.g. USDC)
- Deployed contracts on Base:
  - `DelegationManager`: `0xdb9B1e94B5b69Df7e401DDbedE43491141047dB3`
  - `LiFiSwapEnforcer`: `0x47472E8AA7012D1c23336aa28514AE94389318f5`

## Setup

```bash
cd scripts/lifi-swap
npm install
cp .env.example .env
# edit .env — set PRIVATE_KEY and BASE_RPC_URL (full URL with provider key)
```

## Staged workflow

### Stage 1 — Create and save a delegation

```bash
npm run delegation -- create \
  --id usdc-weth-daily \
  --period-amount 1000000 \
  --period-duration 1200

npm run delegation -- list
npm run delegation -- show usdc-weth-daily
```

Saved files live in `delegations/` (gitignored).

### Setup — Approve LiFi diamond (once per delegation)

```bash
npm run approve -- usdc-weth-daily
```

### Stage 2 — Execute swaps

Use `delegation show` to inspect the on-chain budget before running swaps.

```bash
# First swap: 0.5 USDC (within 1 USDC / period budget)
npm run execute -- usdc-weth-daily --amount 500000

npm run delegation -- show usdc-weth-daily

# Over budget: CLI warns locally, then submits to relayer — expect
# relayer estimate or on-chain revert (LiFiSwapEnforcer:period-amount-exceeded)
npm run execute -- usdc-weth-daily --amount 600000

# Within remaining budget
npm run execute -- usdc-weth-daily --amount 500000
```

Dry-run (quote + relayer estimate, no send):

```bash
npm run execute -- usdc-weth-daily --amount 5000000 --dry-run
```

## How it works

1. **`delegation create`** calls `relayer_getCapabilities` to fetch the relayer **`targetAddress`** for Base (not an env var). It probes the [Li.FI API](https://docs.li.fi/) to pin `lifiDiamond`, builds 284-byte enforcer terms, signs delegations to that `targetAddress`, and saves `relayerTargetAddress` in the local file.
2. **`approve` / `execute`** re-fetch capabilities and **fail fast** if `targetAddress` changed since create (recreate with `--force`). They use **`relayer_estimate7710Transaction`** (with `authorizationList` when needed) and **`relayer_getFeeData`** for the fee floor before send.
3. **`execute`** loads the saved delegation, fetches a fresh LiFi quote, signs an EIP-191 quote with the same `PRIVATE_KEY` (`terms.quoteSigner`), patches caveat args, and submits via `relayer_send7710Transaction` with the estimate `context` price lock.
4. **Periodic budget** is tracked on-chain per `delegationHash`; reuse the same saved file across executions.

### Relayer targetAddress

The redemption wallet address comes from the 1Shot relayer at create time. If the relayer rotates it, `approve` and `execute` will error with instructions to recreate:

```bash
npm run delegation -- create --id usdc-weth-daily --force
```

`RELAYER_URL` in `.env` is only the JSON-RPC endpoint override, not the delegate address.

### Fee estimation

`approve` and `execute` use estimate-first submission: mock fee ≥ `minFee` from `relayer_getFeeData`, simulate via `relayer_estimate7710Transaction`, adjust fee from `requiredPaymentAmount` if needed, then send with signed `context`. Use `--dry-run` to see `gasUsed` and `requiredPaymentAmount` without submitting.

## Cross-chain

Set `LIFI_TO_CHAIN` (and matching `LIFI_TO_TOKEN`) when creating the delegation. Terms use LiFi destination chain id and bytes32 asset/recipient encodings. Source-chain `afterHook` will not verify destination delivery.

## References

- [LiFiSwapEnforcer-App-Integration.md](../../LiFiSwapEnforcer-App-Integration.md)
- [LiFiSwapEnforcer-Wallet-Integration.md](../../LiFiSwapEnforcer-Wallet-Integration.md)
- [public-relayer skill](../../.agents/skills/public-relayer/SKILL.md)
