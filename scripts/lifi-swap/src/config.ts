import { readFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { Address, Hex } from "viem";
import { getAddress, isHex } from "viem";

import { BASE_CHAIN_ID, DEFAULT_RELAYER_URL } from "./constants.js";
import type { SwapConfig } from "./types.js";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const packageRoot = join(scriptDir, "..");

function loadEnvFile(): void {
  const envPath = join(packageRoot, ".env");
  if (!existsSync(envPath)) return;

  const content = readFileSync(envPath, "utf8");
  for (const line of content.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const eq = trimmed.indexOf("=");
    if (eq === -1) continue;
    const key = trimmed.slice(0, eq).trim();
    let value = trimmed.slice(eq + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    if (process.env[key] === undefined) {
      process.env[key] = value;
    }
  }
}

loadEnvFile();

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

function optionalEnv(name: string): string | undefined {
  return process.env[name];
}

function parseBigIntEnv(name: string, fallback?: bigint): bigint {
  const raw = optionalEnv(name);
  if (!raw) {
    if (fallback !== undefined) return fallback;
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return BigInt(raw);
}

function parseAddressEnv(name: string): Address {
  const raw = requireEnv(name);
  return getAddress(raw);
}

function parsePrivateKey(): Hex {
  const raw = requireEnv("PRIVATE_KEY");
  const normalized = raw.startsWith("0x") ? raw : `0x${raw}`;
  if (!isHex(normalized)) {
    throw new Error("PRIVATE_KEY must be a hex string");
  }
  return normalized;
}

function parseOptionalHexEnv(name: string): Hex | undefined {
  const raw = optionalEnv(name);
  if (!raw) return undefined;
  const normalized = raw.startsWith("0x") ? raw : `0x${raw}`;
  if (!isHex(normalized)) {
    throw new Error(`${name} must be a hex string`);
  }
  return normalized;
}

export function loadSwapConfig(overrides: Partial<SwapConfig> = {}): SwapConfig {
  const rpcUrl =
    overrides.rpcUrl ??
    optionalEnv("BASE_RPC_URL") ??
    (() => {
      throw new Error("Missing BASE_RPC_URL in scripts/lifi-swap/.env");
    })();

  return {
    privateKey: overrides.privateKey ?? parsePrivateKey(),
    rpcUrl,
    fromToken: overrides.fromToken ?? parseAddressEnv("LIFI_FROM_TOKEN"),
    toToken: overrides.toToken ?? requireEnv("LIFI_TO_TOKEN"),
    fromAmount: overrides.fromAmount ?? parseBigIntEnv("LIFI_FROM_AMOUNT"),
    toChain: overrides.toChain ?? Number(optionalEnv("LIFI_TO_CHAIN") ?? BASE_CHAIN_ID),
    slippage: overrides.slippage ?? Number(optionalEnv("LIFI_SLIPPAGE") ?? "0.005"),
    periodAmount:
      overrides.periodAmount ?? parseBigIntEnv("LIFI_PERIOD_AMOUNT", 10_000_000n),
    periodDuration:
      overrides.periodDuration ??
      Number(optionalEnv("LIFI_PERIOD_DURATION") ?? "86400"),
    slippageBps: overrides.slippageBps ?? Number(optionalEnv("LIFI_SLIPPAGE_BPS") ?? "50"),
    relayerUrl: overrides.relayerUrl ?? optionalEnv("RELAYER_URL") ?? DEFAULT_RELAYER_URL,
    outputRecipient: overrides.outputRecipient ?? optionalEnv("LIFI_OUTPUT_RECIPIENT"),
    outputAssetIdOverride:
      overrides.outputAssetIdOverride ?? parseOptionalHexEnv("LIFI_OUTPUT_ASSET_ID"),
    outputRecipientBytes32Override:
      overrides.outputRecipientBytes32Override ??
      parseOptionalHexEnv("LIFI_OUTPUT_RECIPIENT_BYTES32"),
  };
}

export function getDelegationsDir(): string {
  return join(scriptDir, "../delegations");
}

export function parseArgs(argv: string[]): {
  positional: string[];
  flags: Record<string, string | boolean>;
} {
  const positional: string[] = [];
  const flags: Record<string, string | boolean> = {};

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (!arg.startsWith("--")) {
      positional.push(arg);
      continue;
    }
    const key = arg.slice(2);
    const next = argv[i + 1];
    if (!next || next.startsWith("--")) {
      flags[key] = true;
    } else {
      flags[key] = next;
      i++;
    }
  }

  return { positional, flags };
}

export function flagBigInt(
  flags: Record<string, string | boolean>,
  key: string,
): bigint | undefined {
  const value = flags[key];
  if (typeof value !== "string") return undefined;
  return BigInt(value);
}

export function flagNumber(
  flags: Record<string, string | boolean>,
  key: string,
): number | undefined {
  const value = flags[key];
  if (typeof value !== "string") return undefined;
  return Number(value);
}

export function flagString(
  flags: Record<string, string | boolean>,
  key: string,
): string | undefined {
  const value = flags[key];
  return typeof value === "string" ? value : undefined;
}

export function flagBool(flags: Record<string, string | boolean>, key: string): boolean {
  return flags[key] === true;
}
