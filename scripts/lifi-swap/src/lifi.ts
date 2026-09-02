import { getAddress, isAddress, type Address, type Hex } from "viem";

import { BASE_CHAIN_ID, LIFI_API_BASE } from "./constants.js";
import { addressToBytes32, encodeLiFiNonEvmBytes32 } from "./terms.js";
import type { SavedDelegation } from "./types.js";

export type LiFiQuoteResponse = {
  transactionRequest: {
    to: Address;
    data: Hex;
    value: string;
    from?: Address;
    chainId?: number;
  };
  estimate: {
    fromAmount: string;
    toAmount: string;
    toAmountMin: string;
  };
  action?: {
    fromToken?: { address?: string; symbol?: string; chainId?: number };
    toToken?: { address?: string; symbol?: string; chainId?: number };
  };
};

export function isEvmSameChainDest(toChain: number, sourceChain: number): boolean {
  return toChain === sourceChain;
}

export function resolveTermsEncodings(params: {
  toChain: number;
  sourceChain: number;
  toToken: string;
  outputRecipient: string;
  outputAssetIdOverride?: Hex;
  outputRecipientBytes32Override?: Hex;
}): { outputAssetId: Hex; outputRecipient: Hex } {
  if (isEvmSameChainDest(params.toChain, params.sourceChain)) {
    if (!isAddress(params.toToken)) {
      throw new Error(
        `LIFI_TO_TOKEN must be an EVM address for same-chain swaps: ${params.toToken}`,
      );
    }
    if (!isAddress(params.outputRecipient)) {
      throw new Error(
        `Output recipient must be an EVM address for same-chain swaps: ${params.outputRecipient}`,
      );
    }
    return {
      outputAssetId: addressToBytes32(getAddress(params.toToken)),
      outputRecipient: addressToBytes32(getAddress(params.outputRecipient)),
    };
  }

  return {
    outputAssetId:
      params.outputAssetIdOverride ?? encodeLiFiNonEvmBytes32(params.toToken),
    outputRecipient:
      params.outputRecipientBytes32Override ??
      encodeLiFiNonEvmBytes32(params.outputRecipient),
  };
}

export function resolveQuoteToAddress(saved: SavedDelegation, delegator: Address): string {
  if (saved.metadata?.outputRecipient) {
    return saved.metadata.outputRecipient;
  }
  if (isEvmSameChainDest(Number(saved.terms.destinationChainId), BASE_CHAIN_ID)) {
    return delegator;
  }
  throw new Error(
    "Missing output recipient in saved delegation metadata; recreate with --output-recipient or LIFI_OUTPUT_RECIPIENT",
  );
}

export async function fetchLiFiQuote(params: {
  fromChain: number;
  toChain: number;
  fromToken: Address;
  toToken: string;
  fromAmount: bigint;
  fromAddress: Address;
  slippage: number;
  toAddress?: string;
}): Promise<LiFiQuoteResponse> {
  const url = new URL(`${LIFI_API_BASE}/quote`);
  url.searchParams.set("fromChain", String(params.fromChain));
  url.searchParams.set("toChain", String(params.toChain));
  url.searchParams.set("fromToken", params.fromToken);
  url.searchParams.set("toToken", params.toToken);
  url.searchParams.set("fromAmount", params.fromAmount.toString());
  url.searchParams.set("fromAddress", params.fromAddress);
  url.searchParams.set("slippage", String(params.slippage));
  if (params.toAddress) {
    url.searchParams.set("toAddress", params.toAddress);
  }

  const response = await fetch(url);
  if (!response.ok) {
    const body = await response.text();
    throw new Error(`LiFi quote failed (${response.status}): ${body}`);
  }

  return (await response.json()) as LiFiQuoteResponse;
}

export function parseQuoteAmounts(quote: LiFiQuoteResponse): {
  expectedAmountOut: bigint;
  minAmountOut: bigint;
} {
  return {
    expectedAmountOut: BigInt(quote.estimate.toAmount),
    minAmountOut: BigInt(quote.estimate.toAmountMin),
  };
}

export function assertQuoteValueZero(quote: LiFiQuoteResponse): void {
  const value = BigInt(quote.transactionRequest.value);
  if (value !== 0n) {
    throw new Error("LiFi quote requires msg.value > 0; LiFiSwapEnforcer v1 only supports value=0");
  }
}

export function extractSymbols(quote: LiFiQuoteResponse): {
  inputSymbol?: string;
  outputSymbol?: string;
} {
  return {
    inputSymbol: quote.action?.fromToken?.symbol,
    outputSymbol: quote.action?.toToken?.symbol,
  };
}

export function assertQuoteDiamond(quote: LiFiQuoteResponse, expectedDiamond: Address): void {
  const actual = getAddress(quote.transactionRequest.to);
  if (actual.toLowerCase() !== expectedDiamond.toLowerCase()) {
    throw new Error(`LiFi diamond mismatch: quote=${actual}, terms=${expectedDiamond}`);
  }
}
