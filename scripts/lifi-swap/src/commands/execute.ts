import { flagBigInt, flagBool, loadSwapConfig, parseArgs } from "../config.js";
import { BASE_CHAIN_ID, QUOTE_EXPIRATION_SECONDS } from "../constants.js";
import {
  createFeeDelegation,
  createSmartAccountContext,
  encodeTransferCalldata,
  readAvailableBudget,
  readErc20Allowance,
} from "../delegations.js";
import { patchSwapDelegationArgs, relayerExecution } from "../encodings.js";
import {
  assertQuoteDiamond,
  assertQuoteValueZero,
  fetchLiFiQuote,
  parseQuoteAmounts,
  resolveQuoteToAddress,
} from "../lifi.js";
import { encodeQuoteArgs, signQuote, verifyQuoteSigner } from "../quote.js";
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
import { hashCalldata, minAmountOutMeetsSlippage, termsRecordToEncoded } from "../terms.js";
import type { SignedLiFiQuote } from "../types.js";

export async function runExecuteCommand(argv: string[]): Promise<void> {
  const { positional, flags } = parseArgs(argv);
  const id = positional[0];
  if (!id) {
    throw new Error("Usage: execute <id> [--amount <atoms>] [--dry-run] [--skip-approve]");
  }

  const dryRun = flagBool(flags, "dry-run");
  const skipApprove = flagBool(flags, "skip-approve");
  const config = loadSwapConfig({
    fromAmount: flagBigInt(flags, "amount"),
  });

  const saved = loadDelegation(id);
  const ctx = await createSmartAccountContext(config.privateKey, config.rpcUrl);

  if (ctx.account.address.toLowerCase() !== saved.terms.quoteSigner.toLowerCase()) {
    throw new Error("PRIVATE_KEY account must match saved terms.quoteSigner");
  }

  const chainCaps = await getChainCapabilities(BASE_CHAIN_ID, config.relayerUrl);
  assertSavedRelayerTarget(saved, chainCaps.targetAddress);

  if (!skipApprove) {
    const allowance = await readErc20Allowance(
      ctx,
      saved.terms.inputToken,
      saved.terms.lifiDiamond,
    );
    if (allowance < config.fromAmount) {
      throw new Error(
        `Insufficient allowance (${allowance}). Run: npm run approve -- ${id}`,
      );
    }
  }

  const termsBytes = termsRecordToEncoded(saved.terms);
  const budget = await readAvailableBudget(ctx, saved.delegationHash, termsBytes);
  if (config.fromAmount > budget.available) {
    console.warn(
      `Warning: requested amount ${config.fromAmount} exceeds available period budget ${budget.available}. ` +
        `Proceeding to relayer — LiFiSwapEnforcer may revert (period-amount-exceeded).`,
    );
  }

  const toAddress = resolveQuoteToAddress(saved, ctx.delegator);

  const lifiQuote = await fetchLiFiQuote({
    fromChain: BASE_CHAIN_ID,
    toChain: Number(saved.terms.destinationChainId),
    fromToken: saved.terms.inputToken,
    toToken: saved.toToken,
    fromAmount: config.fromAmount,
    fromAddress: ctx.delegator,
    slippage: config.slippage,
    toAddress,
  });

  assertQuoteValueZero(lifiQuote);
  assertQuoteDiamond(lifiQuote, saved.terms.lifiDiamond);

  const { expectedAmountOut, minAmountOut } = parseQuoteAmounts(lifiQuote);
  const slippageBps = BigInt(saved.terms.slippageBps);
  if (!minAmountOutMeetsSlippage(minAmountOut, expectedAmountOut, slippageBps)) {
    throw new Error("LiFi quote fails on-chain slippage check");
  }

  const diamondCalldata = lifiQuote.transactionRequest.data;
  const signedQuote: SignedLiFiQuote = {
    delegator: saved.delegator,
    lifiDiamond: saved.terms.lifiDiamond,
    inputToken: saved.terms.inputToken,
    outputAssetId: saved.terms.outputAssetId,
    outputRecipient: saved.terms.outputRecipient,
    destinationChainId: BigInt(saved.terms.destinationChainId),
    inputAmount: config.fromAmount,
    expectedAmountOut,
    minAmountOut,
    calldataHash: hashCalldata(diamondCalldata),
    expiration: BigInt(Math.floor(Date.now() / 1000) + QUOTE_EXPIRATION_SECONDS),
  };

  const signature = await signQuote(
    ctx.account,
    signedQuote,
    saved.delegationHash,
    BASE_CHAIN_ID,
  );

  if (
    !(await verifyQuoteSigner(
      signedQuote,
      saved.delegationHash,
      BASE_CHAIN_ID,
      signature,
      saved.terms.quoteSigner,
    ))
  ) {
    throw new Error("Quote signature verification failed locally");
  }

  const patchedSwapDelegation = patchSwapDelegationArgs(
    saved.swapDelegation,
    encodeQuoteArgs(signedQuote, signature),
  );

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
            permissionContext: serializeDelegations([patchedSwapDelegation]),
            executions: [relayerExecution(saved.terms.lifiDiamond, 0n, diamondCalldata)],
          },
        ],
      };
    },
  });

  if (dryRun) {
    console.log("Dry run execute estimate succeeded.");
    console.log(`  inputAmount:       ${config.fromAmount.toString()}`);
    console.log(`  expectedAmountOut: ${expectedAmountOut.toString()}`);
    console.log(`  minAmountOut:      ${minAmountOut.toString()}`);
    console.log(`  availableBefore:   ${budget.available.toString()}`);
    logEstimateResult(prepared.estimate, " ");
    return;
  }

  const taskId = await sendPreparedTransaction(prepared, config.relayerUrl, {
    memo: `lifi-swap:${id}`,
  });

  console.log(`Swap submitted. taskId=${taskId}`);
  logEstimateResult(prepared.estimate);

  const result = await pollUntilTerminal(taskId, config.relayerUrl);
  if (!result.ok) {
    throw new Error(`Swap failed: ${result.reason ?? "unknown"}`);
  }

  const budgetAfter = await readAvailableBudget(ctx, saved.delegationHash, termsBytes);
  console.log(`Swap confirmed. tx=${result.hash}`);
  console.log(`  availableAfter: ${budgetAfter.available.toString()}`);
}
