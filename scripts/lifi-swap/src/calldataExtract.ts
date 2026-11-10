import { type Hex } from "viem";

export type NonEvmBridgeKind = "near" | "layerswap" | "mayan" | "allbridge";

const NON_EVM_FIELD_OFFSET: Record<NonEvmBridgeKind, number> = {
  near: 0x00,
  layerswap: 0x60,
  mayan: 0x00,
  allbridge: 0x00,
};

function readWord(data: Uint8Array, offset: number): Hex {
  if (data.length < 32 || offset > data.length - 32) {
    throw new Error("calldata too short for nonEVMRecipient read");
  }
  const slice = data.slice(offset, offset + 32);
  return `0x${Buffer.from(slice).toString("hex")}` as Hex;
}

function bridgeDataBody(data: Uint8Array): number {
  const bdOff = Number(readBigEndianWord(data, 0x04));
  return 0x04 + bdOff;
}

function readBigEndianWord(data: Uint8Array, offset: number): bigint {
  if (data.length < offset + 32) {
    throw new Error("calldata too short");
  }
  let value = 0n;
  for (let i = 0; i < 32; i++) {
    value = (value << 8n) | BigInt(data[offset + i]!);
  }
  return value;
}

const SWAP_SELECTORS = new Set(["3110c7b9", "4c279d6b", "80c65808", "63267469"]);
const START_SELECTORS = new Set(["5cf8113b", "ee9e98e0", "b4875292", "6a51e9a9"]);

function bridgeSpecificStructBody(data: Uint8Array, routeKind: NonEvmBridgeKind): number {
  const selector = Buffer.from(data.subarray(0, 4)).toString("hex");
  const isSwap = SWAP_SELECTORS.has(selector);
  const isStart = START_SELECTORS.has(selector);
  if (!isSwap && !isStart) {
    throw new Error("unsupported bridge selector");
  }
  const bd = bridgeDataBody(data);
  const hasSourceSwaps = readBigEndianWord(data, bd + 0x100) !== 0n;
  if (hasSourceSwaps !== isSwap) {
    throw new Error("source-swaps-mismatch");
  }
  // start* is a two-parameter call (head at 0x24). swapAndStart* is three parameters (head at 0x44).
  const headSlotAbs = isSwap ? 0x44 : 0x24;
  // AllBridgeData is a static tuple, so the struct is inlined at the head slot.
  // Mayan, NEAR, and LayerSwap structs are dynamic and sit behind the offset stored there.
  if (routeKind === "allbridge") return headSlotAbs;
  const structOff = Number(readBigEndianWord(data, headSlotAbs));
  return 0x04 + structOff;
}

/** Extract the non-EVM recipient bytes32 from LiFi swap+bridge calldata. */
export function extractNonEvmRecipientBytes32(
  calldata: Hex,
  routeKind: NonEvmBridgeKind,
): Hex {
  const hex = calldata.startsWith("0x") ? calldata.slice(2) : calldata;
  const data = Uint8Array.from(Buffer.from(hex, "hex"));
  if (data.length < 4) {
    throw new Error("calldata too short");
  }
  const structBody = bridgeSpecificStructBody(data, routeKind);
  return readWord(data, structBody + NON_EVM_FIELD_OFFSET[routeKind]);
}
