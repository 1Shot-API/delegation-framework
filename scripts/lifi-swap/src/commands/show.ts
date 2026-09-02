import { parseArgs } from "../config.js";
import {
  createSmartAccountContext,
  readAvailableBudget,
} from "../delegations.js";
import { loadDelegation } from "../store.js";
import { termsRecordToEncoded } from "../terms.js";

export async function runShowCommand(argv: string[]): Promise<void> {
  const { positional } = parseArgs(argv);
  const id = positional[0];
  if (!id) {
    throw new Error("Usage: delegation show <id>");
  }

  const saved = loadDelegation(id);
  const config = (await import("../config.js")).loadSwapConfig();
  const ctx = await createSmartAccountContext(config.privateKey, config.rpcUrl);

  if (ctx.account.address.toLowerCase() !== saved.terms.quoteSigner.toLowerCase()) {
    throw new Error("PRIVATE_KEY does not match saved quoteSigner");
  }

  const termsBytes = termsRecordToEncoded(saved.terms);
  const budget = await readAvailableBudget(ctx, saved.delegationHash, termsBytes);

  console.log(JSON.stringify(saved, null, 2));
  console.log("\nOn-chain budget:");
  console.log(`  availableAmount:  ${budget.available.toString()}`);
  console.log(`  isNewPeriod:      ${budget.isNewPeriod}`);
  console.log(`  currentPeriod:    ${budget.currentPeriod.toString()}`);
}
