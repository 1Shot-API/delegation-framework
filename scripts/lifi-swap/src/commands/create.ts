import { getAddress, type Address } from "viem";

import {
  flagBigInt,
  flagBool,
  flagNumber,
  flagString,
  loadSwapConfig,
  parseArgs,
} from "../config.js";
import { BASE_CHAIN_ID } from "../constants.js";
import {
  createApproveDelegation,
  createSmartAccountContext,
  createSwapDelegation,
} from "../delegations.js";
import {
  assertQuoteValueZero,
  extractSymbols,
  fetchLiFiQuote,
  resolveOutputAssetId,
  resolveOutputRecipient,
} from "../lifi.js";
import { getChainCapabilities } from "../relayer.js";
import { delegationExists, saveDelegation } from "../store.js";
import { addressToBytes32, encodeLiFiTerms } from "../terms.js";
import type { LiFiTermsRecord, SavedDelegation } from "../types.js";

function defaultId(config: ReturnType<typeof loadSwapConfig>): string {
  return `base-${config.fromToken.slice(-4)}-${config.toToken.slice(-4)}-${config.periodAmount}-${config.periodDuration}s`;
}

export async function runCreateCommand(argv: string[]): Promise<void> {
  const { flags } = parseArgs(argv);
  const config = loadSwapConfig({
    fromAmount: flagBigInt(flags, "amount") ?? undefined,
    toChain: flagNumber(flags, "to-chain"),
    periodAmount: flagBigInt(flags, "period-amount"),
    periodDuration: flagNumber(flags, "period-duration"),
    slippageBps: flagNumber(flags, "slippage-bps"),
  });

  const id = flagString(flags, "id") ?? defaultId(config);
  const name = flagString(flags, "name") ?? id;
  const force = flagBool(flags, "force");
  const withApprove = !flagBool(flags, "no-approve");
  const probeAmount = flagBigInt(flags, "probe-amount") ?? 1_000n;

  if (delegationExists(id) && !force) {
    throw new Error(`Delegation "${id}" already exists. Pass --force to overwrite.`);
  }

  const ctx = await createSmartAccountContext(config.privateKey, config.rpcUrl);
  const chainCaps = await getChainCapabilities(BASE_CHAIN_ID, config.relayerUrl);

  const probeQuote = await fetchLiFiQuote({
    fromChain: BASE_CHAIN_ID,
    toChain: config.toChain,
    fromToken: config.fromToken,
    toToken: config.toToken,
    fromAmount: probeAmount,
    fromAddress: ctx.delegator,
    slippage: config.slippage,
  });
  assertQuoteValueZero(probeQuote);

  const lifiDiamond = getAddress(probeQuote.transactionRequest.to);
  const outputRecipientAddress = config.outputRecipient ?? ctx.delegator;
  const startDate = BigInt(Math.floor(Date.now() / 1000));

  const terms: LiFiTermsRecord = {
    lifiDiamond,
    inputToken: config.fromToken,
    outputAssetId: resolveOutputAssetId(config.toChain, BASE_CHAIN_ID, config.toToken),
    outputRecipient: resolveOutputRecipient(outputRecipientAddress),
    destinationChainId: String(config.toChain),
    quoteSigner: ctx.account.address,
    periodAmount: config.periodAmount.toString(),
    periodDuration: String(config.periodDuration),
    startDate: startDate.toString(),
    slippageBps: config.slippageBps,
  };

  const { delegation: swapDelegation, delegationHash } = await createSwapDelegation(
    ctx,
    chainCaps.targetAddress,
    terms,
  );

  let approveDelegation;
  if (withApprove) {
    approveDelegation = await createApproveDelegation(
      ctx,
      chainCaps.targetAddress,
      config.fromToken,
      lifiDiamond,
    );
  }

  const symbols = extractSymbols(probeQuote);
  const saved: SavedDelegation = {
    id,
    name,
    createdAt: new Date().toISOString(),
    chainId: BASE_CHAIN_ID,
    delegator: ctx.delegator,
    delegationHash,
    toToken: config.toToken,
    relayerTargetAddress: chainCaps.targetAddress,
    relayerUrl: config.relayerUrl,
    terms,
    swapDelegation,
    approveDelegation,
    metadata: {
      inputSymbol: symbols.inputSymbol,
      outputSymbol: symbols.outputSymbol,
      toChain: String(config.toChain),
    },
  };

  const path = saveDelegation(saved, { force });
  const termsBytes = encodeLiFiTerms({
    lifiDiamond: terms.lifiDiamond,
    inputToken: terms.inputToken,
    outputAssetId: terms.outputAssetId,
    outputRecipient: terms.outputRecipient,
    destinationChainId: BigInt(terms.destinationChainId),
    quoteSigner: terms.quoteSigner,
    periodAmount: BigInt(terms.periodAmount),
    periodDuration: BigInt(terms.periodDuration),
    startDate: BigInt(terms.startDate),
    slippageBps: BigInt(terms.slippageBps),
  });

  console.log("Saved delegation:");
  console.log(`  id:              ${id}`);
  console.log(`  path:            ${path}`);
  console.log(`  delegator:       ${ctx.delegator}`);
  console.log(`  delegationHash:  ${delegationHash}`);
  console.log(`  lifiDiamond:     ${lifiDiamond}`);
  console.log(`  periodAmount:    ${terms.periodAmount}`);
  console.log(`  periodDuration:  ${terms.periodDuration}s`);
  console.log(`  startDate:       ${terms.startDate}`);
  console.log(`  termsBytes:      ${termsBytes}`);
  console.log(`  relayerTarget:   ${saved.relayerTargetAddress}`);
}
