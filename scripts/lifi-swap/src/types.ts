import type { Delegation } from "@metamask/smart-accounts-kit";
import type { Address, Hex } from "viem";

export type LiFiTermsRecord = {
  lifiDiamond: Address;
  inputToken: Address;
  outputAssetId: Hex;
  outputRecipient: Hex;
  destinationChainId: string;
  quoteSigner: Address;
  periodAmount: string;
  periodDuration: string;
  startDate: string;
  slippageBps: number;
};

export type SavedDelegationMetadata = {
  inputSymbol?: string;
  outputSymbol?: string;
  toChain?: string;
};

export type SavedDelegation = {
  id: string;
  name: string;
  createdAt: string;
  chainId: number;
  delegator: Address;
  delegationHash: Hex;
  toToken: Address;
  /** Set at create from relayer_getCapabilities; absent on pre-migration saved files */
  relayerTargetAddress?: Address;
  relayerUrl?: string;
  terms: LiFiTermsRecord;
  swapDelegation: Delegation;
  approveDelegation?: Delegation;
  metadata?: SavedDelegationMetadata;
};

export type ManifestEntry = {
  id: string;
  name: string;
  createdAt: string;
  delegationHash: Hex;
  periodAmount: string;
  periodDuration: string;
};

export type Manifest = {
  delegations: ManifestEntry[];
};

export type SignedLiFiQuote = {
  delegator: Address;
  lifiDiamond: Address;
  inputToken: Address;
  outputAssetId: Hex;
  outputRecipient: Hex;
  destinationChainId: bigint;
  inputAmount: bigint;
  expectedAmountOut: bigint;
  minAmountOut: bigint;
  calldataHash: Hex;
  expiration: bigint;
};

export type SwapConfig = {
  privateKey: Hex;
  rpcUrl: string;
  fromToken: Address;
  toToken: Address;
  fromAmount: bigint;
  toChain: number;
  slippage: number;
  periodAmount: bigint;
  periodDuration: number;
  slippageBps: number;
  relayerUrl: string;
  outputRecipient?: Address;
};
