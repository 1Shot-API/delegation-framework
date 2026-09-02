import { getAddress, type Address, type Hex } from "viem";

import { LIFI_API_BASE } from "./constants.js";
import { addressToBytes32 } from "./terms.js";

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

export async function fetchLiFiQuote(params: {
  fromChain: number;
  toChain: number;
  fromToken: Address;
  toToken: Address;
  fromAmount: bigint;
  fromAddress: Address;
  slippage: number;
}): Promise<LiFiQuoteResponse> {
  const url = new URL(`${LIFI_API_BASE}/quote`);
  url.searchParams.set("fromChain", String(params.fromChain));
  url.searchParams.set("toChain", String(params.toChain));
  url.searchParams.set("fromToken", params.fromToken);
  url.searchParams.set("toToken", params.toToken);
  url.searchParams.set("fromAmount", params.fromAmount.toString());
  url.searchParams.set("fromAddress", params.fromAddress);
  url.searchParams.set("slippage", String(params.slippage));

  const response = await fetch(url);
  if (!response.ok) {
    const body = await response.text();
    throw new Error(`LiFi quote failed (${response.status}): ${body}`);
  }

  return (await response.json()) as LiFiQuoteResponse;
}

export function resolveOutputAssetId(toChain: number, sourceChain: number, toToken: Address): Hex {
  if (toChain === sourceChain) {
    return addressToBytes32(toToken);
  }
  return addressToBytes32(toToken);
}

export function resolveOutputRecipient(recipient: Address): Hex {
  return addressToBytes32(recipient);
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
