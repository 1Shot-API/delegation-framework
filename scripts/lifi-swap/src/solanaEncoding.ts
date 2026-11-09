import { padHex, toHex, type Hex } from "viem";

const BASE58_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

/**
 * Decode a base58 string. Returns undefined when a character is outside the Bitcoin/Solana alphabet.
 * Leading `1`s become leading zero bytes.
 */
export function decodeBase58(value: string): Uint8Array | undefined {
  const trimmed = value.trim();
  if (trimmed.length === 0) return undefined;

  let zeros = 0;
  while (zeros < trimmed.length && trimmed[zeros] === "1") zeros++;

  const bytes: number[] = [];
  for (let i = zeros; i < trimmed.length; i++) {
    const digit = BASE58_ALPHABET.indexOf(trimmed[i]!);
    if (digit < 0) return undefined;
    let carry = digit;
    for (let j = 0; j < bytes.length; j++) {
      carry += bytes[j]! * 58;
      bytes[j] = carry & 0xff;
      carry >>= 8;
    }
    while (carry > 0) {
      bytes.push(carry & 0xff);
      carry >>= 8;
    }
  }

  const out = new Uint8Array(zeros + bytes.length);
  for (let i = 0; i < bytes.length; i++) {
    out[out.length - 1 - i] = bytes[i]!;
  }
  return out;
}

/**
 * LiFi stores a Solana pubkey or SPL mint as the raw 32-byte base58 decode, not a hash of the text.
 * Returns undefined when `value` is not a 32-byte base58 payload.
 */
export function tryEncodeSolanaBytes32(value: string): Hex | undefined {
  const decoded = decodeBase58(value);
  if (!decoded || decoded.length !== 32) return undefined;
  return padHex(toHex(decoded), { size: 32 });
}
