import { maxUint256 } from "viem";

import { flagBool, loadSwapConfig, parseArgs } from "../config.js";
import { BASE_CHAIN_ID } from "../constants.js";
import {
  createFeeDelegation,
  createSmartAccountContext,
  encodeApproveCalldata,
  encodeTransferCalldata,
  readErc20Allowance,
} from "../delegations.js";
import { relayerExecution } from "../encodings.js";
import {
  estimateAndPrepareSend,
  logEstimateResult,
  sendPreparedTransaction,
} from "../relaySubmit.js";
import {
  assertSavedRelayerTarget,
  findUsdcToken,
  getChainCapabilities,
  pollUntilTerminal,
  serializeDelegations,
} from "../relayer.js";
import { loadDelegation } from "../store.js";

export async function runApproveCommand(argv: string[]): Promise<void> {
  const { positional, flags } = parseArgs(argv);
  const id = positional[0];
  if (!id) {
    throw new Error("Usage: approve <id>");
  }

  const dryRun = flagBool(flags, "dry-run");
  const config = loadSwapConfig();
  const saved = loadDelegation(id);
  const ctx = await createSmartAccountContext(config.privateKey, config.rpcUrl);

  const allowance = await readErc20Allowance(ctx, saved.terms.inputToken, saved.terms.lifiDiamond);
  if (allowance >= maxUint256 / 2n) {
    console.log(`Allowance already sufficient: ${allowance.toString()}`);
    return;
  }

  const chainCaps = await getChainCapabilities(BASE_CHAIN_ID, config.relayerUrl);
  assertSavedRelayerTarget(saved, chainCaps.targetAddress);

  const approveDelegation = saved.approveDelegation;
  if (!approveDelegation) {
    throw new Error(
      `No approve delegation saved for "${id}". Recreate with: npm run delegation -- create --id ${id} --force`,
    );
  }

  const paymentToken = findUsdcToken(chainCaps);

  const prepared = await estimateAndPrepareSend({
    ctx,
    chainId: BASE_CHAIN_ID,
    paymentToken: paymentToken.address,
    relayerUrl: config.relayerUrl,
    buildSendParams: async (feeAmount) => {
      const feeDelegation = await createFeeDelegation(
        ctx,
        chainCaps.targetAddress,
        paymentToken.address,
        feeAmount,
      );
      return {
        chainId: String(BASE_CHAIN_ID),
        transactions: [
          {
            permissionContext: serializeDelegations([feeDelegation]),
            executions: [
              relayerExecution(
                paymentToken.address,
                0n,
                encodeTransferCalldata(chainCaps.feeCollector, feeAmount),
              ),
            ],
          },
          {
            permissionContext: serializeDelegations([approveDelegation]),
            executions: [
              relayerExecution(
                saved.terms.inputToken,
                0n,
                encodeApproveCalldata(saved.terms.lifiDiamond),
              ),
            ],
          },
        ],
      };
    },
  });

  if (dryRun) {
    console.log("Dry run approve estimate succeeded.");
    logEstimateResult(prepared.estimate);
    return;
  }

  const taskId = await sendPreparedTransaction(prepared, config.relayerUrl);
  console.log(`Approve submitted. taskId=${taskId}`);
  logEstimateResult(prepared.estimate);

  const result = await pollUntilTerminal(taskId, config.relayerUrl);
  if (!result.ok) {
    throw new Error(`Approve failed: ${result.reason ?? "unknown"}`);
  }
  console.log(`Approve confirmed. tx=${result.hash}`);
}
