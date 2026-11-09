import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, it } from "node:test";
import { keccak256, stringToBytes } from "viem";

import { encodeLiFiBitcoinBytes32, isBitcoinAddress } from "./bitcoinEncoding.js";
import { extractNonEvmRecipientBytes32 } from "./calldataExtract.js";
import type { LiFiChain, LiFiQuoteResponse } from "./lifiApi.js";
import { resolveTermsEncodings } from "./lifi.js";
import { deriveRouteKind } from "./quote.js";
import { encodeLiFiNonEvmBytes32 } from "./terms.js";
import { RouteKind } from "./types.js";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const packageRoot = join(scriptDir, "..");

const BTC_RECIPIENT = "bc1q9vpk73hpnvrv6mdsxrsc0as03ycywjr0qkja7h";
const EXPECTED_BYTES32 =
  "0x050c01161e111701130c030c1a1b0d10060310180f1d100f110418040e12030f";

const bitcoinChain: LiFiChain = {
  key: "btc",
  name: "Bitcoin",
  coin: "BTC",
  id: 20000000000001,
  mainnet: true,
  chainType: "UTXO",
};

function loadFixture(name: string): { transactionRequest: { data: string } } {
  const raw = readFileSync(join(packageRoot, name), "utf8");
  return JSON.parse(raw) as { transactionRequest: { data: string } };
}

describe("encodeLiFiBitcoinBytes32", () => {
  it("encodes bc1q P2WPKH to LiFi calldata bytes32", () => {
    assert.equal(encodeLiFiBitcoinBytes32(BTC_RECIPIENT), EXPECTED_BYTES32);
  });

  it("isBitcoinAddress detects bc1/tb1 only", () => {
    assert.equal(isBitcoinAddress(BTC_RECIPIENT), true);
    assert.equal(isBitcoinAddress("tb1q9vpk73hpnvrv6mdsxrsc0as03ycywjr0qkja7h"), true);
    assert.equal(isBitcoinAddress("HoJQwEF9VZVQREpwACNjMiQEkvZDwWYPHGuAdAHkX6dw"), false);
  });
});

const SOLANA_RECIPIENT = "7xKXtg2CW87d97TXJSDpbD5jBkheTqA83TZRuJosgAsU";
const SOLANA_RECIPIENT_BYTES32 =
  "0x6752055c20b3e9d8746656ddf73855507f87ab6d87523e4c76a7fa36096a99eb";
const SOLANA_USDC_MINT = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v";
const SOLANA_USDC_BYTES32 =
  "0xc6fa7af3bedbad3a3d65f36aabc97431b1bbe4c2d2f6e0e47ca60203452f5d61";
const SOLANA_SYSTEM_PROGRAM = "11111111111111111111111111111111";

const solanaChain: LiFiChain = {
  key: "sol",
  name: "Solana",
  coin: "SOL",
  id: 1151111081099710,
  mainnet: true,
  chainType: "SVM",
};

describe("encodeLiFiNonEvmBytes32", () => {
  it("uses Bitcoin encoder for bc1 addresses", () => {
    assert.equal(encodeLiFiNonEvmBytes32(BTC_RECIPIENT), EXPECTED_BYTES32);
  });

  it("base58-decodes a 32-byte Solana pubkey", () => {
    assert.equal(encodeLiFiNonEvmBytes32(SOLANA_RECIPIENT), SOLANA_RECIPIENT_BYTES32);
    assert.equal(encodeLiFiNonEvmBytes32(SOLANA_USDC_MINT), SOLANA_USDC_BYTES32);
  });

  it("encodes the Solana system program as 32 zero bytes", () => {
    assert.equal(
      encodeLiFiNonEvmBytes32(SOLANA_SYSTEM_PROGRAM),
      `0x${"00".repeat(32)}`,
    );
  });

  it("still keccak-hashes long non-Bitcoin strings that are not 32-byte base58", () => {
    const long = "a".repeat(42);
    assert.equal(encodeLiFiNonEvmBytes32(long), keccak256(stringToBytes(long)));
  });
});

describe("resolveTermsEncodings BTC route", () => {
  it("uses LiFi binary bytes32 for cross-chain Bitcoin recipient", () => {
    const result = resolveTermsEncodings({
      toChain: bitcoinChain.id,
      sourceChain: 8453,
      toToken: "bitcoin",
      outputRecipient: BTC_RECIPIENT,
      outputChain: bitcoinChain,
    });
    assert.equal(result.outputRecipient, EXPECTED_BYTES32);
  });
});

describe("resolveTermsEncodings Solana route", () => {
  it("uses the raw pubkey and mint for a Solana recipient and asset", () => {
    const result = resolveTermsEncodings({
      toChain: solanaChain.id,
      sourceChain: 8453,
      toToken: SOLANA_USDC_MINT,
      outputRecipient: SOLANA_RECIPIENT,
      outputChain: solanaChain,
    });
    assert.equal(result.outputRecipient, SOLANA_RECIPIENT_BYTES32);
    assert.equal(result.outputAssetId, SOLANA_USDC_BYTES32);
  });
});

describe("deriveRouteKind", () => {
  function nonEvmQuote(tool: string): LiFiQuoteResponse {
    return {
      id: "quote",
      type: "lifi",
      tool,
      action: {
        fromChainId: 8453,
        toChainId: solanaChain.id,
        fromAmount: "1000000",
        toToken: {
          address: SOLANA_USDC_MINT,
          chainId: solanaChain.id,
          decimals: 6,
          symbol: "USDC",
          name: "USDC",
        },
      },
    };
  }

  it("maps Mayan and Allbridge tools onto the new route kinds", () => {
    assert.equal(deriveRouteKind(nonEvmQuote("mayan"), 8453), RouteKind.MayanNonEvm);
    assert.equal(deriveRouteKind(nonEvmQuote("mayanWH"), 8453), RouteKind.MayanNonEvm);
    assert.equal(deriveRouteKind(nonEvmQuote("allbridge"), 8453), RouteKind.AllbridgeNonEvm);
  });

  it("still rejects unsupported non-EVM tools", () => {
    assert.throws(() => deriveRouteKind(nonEvmQuote("relay"), 8453), /Unsupported non-EVM bridge/);
  });
});

describe("calldata round-trip", () => {
  // Saved quote fixtures are local debugging artifacts and are not checked in.
  function skipWithoutFixture(t: { skip: (message?: string) => void }, name: string): boolean {
    if (existsSync(join(packageRoot, name))) return false;
    t.skip(`${name} is not in the repo`);
    return true;
  }

  it("matches encoder output in LAYERSWAP.JSON", (t) => {
    if (skipWithoutFixture(t, "LAYERSWAP.JSON")) return;
    const fixture = loadFixture("LAYERSWAP.JSON");
    const extracted = extractNonEvmRecipientBytes32(
      fixture.transactionRequest.data as `0x${string}`,
      "layerswap",
    );
    assert.equal(extracted, EXPECTED_BYTES32);
    assert.equal(extracted, encodeLiFiBitcoinBytes32(BTC_RECIPIENT));
  });

  it("matches encoder output in NEAR.json", (t) => {
    if (skipWithoutFixture(t, "NEAR.json")) return;
    const fixture = loadFixture("NEAR.json");
    const extracted = extractNonEvmRecipientBytes32(
      fixture.transactionRequest.data as `0x${string}`,
      "near",
    );
    assert.equal(extracted, EXPECTED_BYTES32);
    assert.equal(extracted, encodeLiFiBitcoinBytes32(BTC_RECIPIENT));
  });
});
