import {
  encodeAbiParameters,
  hashMessage,
  keccak256,
  parseAbiParameters,
  recoverAddress,
  type Address,
  type Hex,
  type PrivateKeyAccount,
} from "viem";

import type { SignedLiFiQuote } from "./types.js";

function quoteTuple(quote: SignedLiFiQuote) {
  return [
    quote.delegator,
    quote.lifiDiamond,
    quote.inputToken,
    quote.outputAssetId,
    quote.outputRecipient,
    quote.destinationChainId,
    quote.inputAmount,
    quote.expectedAmountOut,
    quote.minAmountOut,
    quote.calldataHash,
    quote.expiration,
  ] as const;
}

export function hashQuote(
  quote: SignedLiFiQuote,
  delegationHash: Hex,
  chainId: number,
): Hex {
  return keccak256(
    encodeAbiParameters(
      parseAbiParameters(
        "(address,address,address,bytes32,bytes32,uint256,uint256,uint256,uint256,bytes32,uint256), uint256, bytes32, uint256",
      ),
      [quoteTuple(quote), quote.expiration, delegationHash, BigInt(chainId)],
    ),
  );
}

export async function signQuote(
  account: PrivateKeyAccount,
  quote: SignedLiFiQuote,
  delegationHash: Hex,
  chainId: number,
): Promise<Hex> {
  const digest = hashQuote(quote, delegationHash, chainId);
  return account.signMessage({ message: { raw: digest } });
}

export function encodeQuoteArgs(quote: SignedLiFiQuote, signature: Hex): Hex {
  return encodeAbiParameters(
    parseAbiParameters(
      "(address,address,address,bytes32,bytes32,uint256,uint256,uint256,uint256,bytes32,uint256), bytes",
    ),
    [quoteTuple(quote), signature],
  );
}

export async function verifyQuoteSigner(
  quote: SignedLiFiQuote,
  delegationHash: Hex,
  chainId: number,
  signature: Hex,
  expectedSigner: Address,
): Promise<boolean> {
  const digest = hashQuote(quote, delegationHash, chainId);
  const ethSigned = hashMessage({ raw: digest });
  const recovered = await recoverAddress({ hash: ethSigned, signature });
  return recovered.toLowerCase() === expectedSigner.toLowerCase();
}
