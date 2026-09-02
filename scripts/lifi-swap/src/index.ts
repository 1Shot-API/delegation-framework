#!/usr/bin/env tsx

import { runApproveCommand } from "./commands/approve.js";
import { runCreateCommand } from "./commands/create.js";
import { runExecuteCommand } from "./commands/execute.js";
import { runListCommand } from "./commands/list.js";
import { runShowCommand } from "./commands/show.js";

function printHelp(): void {
  console.log(`LiFi Swap CLI (staged grant → execute)

Usage:
  npm run delegation -- create [options]
  npm run delegation -- list
  npm run delegation -- show <id>
  npm run approve -- <id> [--dry-run]
  npm run execute -- <id> [--amount <atoms>] [--dry-run] [--skip-approve]

Create options:
  --id <slug>                 Saved delegation id
  --name <label>              Human-readable name
  --period-amount <atoms>     Period budget (default: LIFI_PERIOD_AMOUNT)
  --period-duration <seconds> Period length (default: LIFI_PERIOD_DURATION)
  --slippage-bps <bps>        On-chain slippage cap (default: LIFI_SLIPPAGE_BPS)
  --to-chain <id>             Destination chain (default: LIFI_TO_CHAIN)
  --output-recipient <addr>   LiFi toAddress (required for cross-chain; Solana pubkey, BTC address)
  --no-approve                Do not save approve delegation alongside swap grant
  --force                     Overwrite existing saved delegation id

Execute options:
  --amount <atoms>            Swap input amount (default: LIFI_FROM_AMOUNT)
  --dry-run                   Quote + relayer estimate only
  --skip-approve              Skip allowance pre-check
                              Over-budget amounts warn locally; enforcer enforces on-chain

Environment (scripts/lifi-swap/.env):
  PRIVATE_KEY, BASE_RPC_URL, LIFI_* , LIFI_OUTPUT_RECIPIENT (cross-chain), RELAYER_URL
`);
}

async function main(): Promise<void> {
  const [, , command, subcommand, ...rest] = process.argv;

  try {
    if (command === "delegation" && subcommand === "create") {
      await runCreateCommand(rest);
      return;
    }
    if (command === "delegation" && subcommand === "list") {
      await runListCommand();
      return;
    }
    if (command === "delegation" && subcommand === "show") {
      await runShowCommand(rest);
      return;
    }
    if (command === "approve") {
      await runApproveCommand([subcommand, ...rest].filter(Boolean));
      return;
    }
    if (command === "execute") {
      await runExecuteCommand([subcommand, ...rest].filter(Boolean));
      return;
    }

    printHelp();
    process.exit(command ? 1 : 0);
  } catch (error) {
    console.error(error instanceof Error ? error.message : error);
    process.exit(1);
  }
}

await main();
