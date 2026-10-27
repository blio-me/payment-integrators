import { ethers } from "hardhat";
import { getIntegratorConfig } from "./lib/diamond";

/**
 * Deploy BlioCheckoutIntegrator — the consumer checkout for blio.me Premium:
 * users pay in local fiat and the Diamond settles USDC on Base straight into
 * the blio Safe.
 *
 *   BlioCheckoutIntegrator
 *   → [--register] register on the Diamond (usdcThroughIntegrator = FALSE)
 *
 * ── Settlement is direct, with no custody ─────────────────────────────────
 * Every order pins `recipientAddr` to the immutable `treasury` (the blio Safe),
 * so completion routes USDC straight there. Registering
 * `usdcThroughIntegrator = true` would route it to the integrator instead,
 * which has no forwarding path — the funds would strand. The script checks the
 * flag and warns if it is ever observed as non-false.
 *
 * ── Registration is opt-in ────────────────────────────────────────────────
 * The Diamond registry is owned by the p2p admin. By default this script only
 * deploys; pass `--register` to submit `registerIntegrator` from the current
 * signer. The live Diamond's selector is
 * `registerIntegrator(address,bool,address,bool)`, which sets the 5-word
 * IntegratorConfig (isActive, usdcThroughIntegrator, cancelCallbackEnabled,
 * activeOrderCount, proxyImpl). `cancelCallbackEnabled` stays false.
 *
 * ── Owner + recipient ─────────────────────────────────────────────────────
 * `owner` (limits, products, pause) and `treasury` (settlement destination)
 * should both be the blio Safe. On mainnet the treasury defaults to the Safe
 * and the script refuses to default the owner to the deployer EOA.
 *
 * Usage:
 *   [DIAMOND_ADDRESS=0x...] [USDC_ADDRESS=0x...] \
 *   [RECIPIENT_ADDR=0x...] ATTESTOR=0x... [DEPLOY_OWNER=0x...] \
 *   [DAILY_TX_COUNT_LIMIT=5] [DRY_RUN=1] [--register] \
 *   npx hardhat run scripts/deploy-blio.ts --network base
 */

const BLIO_SAFE = "0xFB25b3BFc8eCEA01eC70763f92fBc8B3079bdf47";

const DEFAULT_DAILY_TX_COUNT_LIMIT = "5";
const TIER_LIVENESS = 1;
const TIER_PASSPORT = 2;
const INR_CURRENCY = ethers.encodeBytes32String("INR");
const OTHER_CURRENCY = ethers.ZeroHash;

const DEFAULT_LIMITS = [
  { label: "INR / Liveness", currency: INR_CURRENCY, tier: TIER_LIVENESS, limit: 20_000_000n },
  { label: "INR / Passport", currency: INR_CURRENCY, tier: TIER_PASSPORT, limit: 100_000_000n },
  { label: "Other / Liveness", currency: OTHER_CURRENCY, tier: TIER_LIVENESS, limit: 50_000_000n },
  { label: "Other / Passport", currency: OTHER_CURRENCY, tier: TIER_PASSPORT, limit: 200_000_000n },
] as const;

const PRESETS: Record<
  number,
  { label: string; diamond?: string; usdc?: string; recipient?: string }
> = {
  8453: {
    label: "Base mainnet",
    diamond: "0x4cad6eC90e65baBec9335cAd728DDC610c316368",
    usdc: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
    recipient: BLIO_SAFE,
  },
  84532: { label: "Base Sepolia" },
};

const DAILY_TX_COUNT_LIMIT = process.env.DAILY_TX_COUNT_LIMIT || DEFAULT_DAILY_TX_COUNT_LIMIT;
const REGISTER = process.argv.includes("--register");
const DRY_RUN = process.env.DRY_RUN === "1" || process.env.DRY_RUN === "true";

const REGISTER_ABI = [
  "function registerIntegrator(address integrator, bool usdcThroughIntegrator, address proxyImpl, bool cancelCallbackEnabled)",
];

const ERC20_ABI = [
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
];

function requireChecksummed(label: string, addr: string): string {
  let checksummed: string;
  try {
    checksummed = ethers.getAddress(addr.toLowerCase());
  } catch {
    throw new Error(`${label} is not an address: ${addr}`);
  }
  if (addr !== checksummed) {
    throw new Error(
      `${label} fails its EIP-55 checksum: got ${addr}. Re-copy the address from ` +
        `the source of truth rather than "fixing" the casing.`
    );
  }
  return checksummed;
}

function warn(message: string): void {
  console.log(`   ⚠️  ${message}`);
}

async function main() {
  const [deployer] = await ethers.getSigners();
  const net = await ethers.provider.getNetwork();
  const chainId = Number(net.chainId);
  const preset = PRESETS[chainId];
  const isMainnet = chainId === 8453;

  if (!preset) throw new Error(`Unsupported chainId ${chainId} — expected 8453 or 84532`);

  const DIAMOND_ADDRESS = process.env.DIAMOND_ADDRESS || preset.diamond || "";
  const USDC_ADDRESS = process.env.USDC_ADDRESS || preset.usdc || "";
  const RECIPIENT_ADDR =
    process.env.RECIPIENT_ADDR || process.env.TREASURY || preset.recipient || "";
  const ATTESTOR = process.env.ATTESTOR || "";
  const DEPLOY_OWNER = process.env.DEPLOY_OWNER || deployer.address;

  console.log(`\n=== BlioCheckoutIntegrator — ${preset.label} (${chainId}) ===`);
  console.log("Deployer:", deployer.address);
  console.log(
    "Balance: ",
    ethers.formatEther(await ethers.provider.getBalance(deployer.address)),
    "ETH"
  );

  if (!DIAMOND_ADDRESS || !USDC_ADDRESS) {
    throw new Error("DIAMOND_ADDRESS and USDC_ADDRESS are required (no preset on this network)");
  }
  if (!RECIPIENT_ADDR) {
    throw new Error("RECIPIENT_ADDR is required — the blio Safe that receives settlement");
  }
  const recipient = requireChecksummed("RECIPIENT_ADDR", RECIPIENT_ADDR);
  if (recipient === ethers.ZeroAddress) throw new Error("RECIPIENT_ADDR must be non-zero");

  if (!ATTESTOR) throw new Error("ATTESTOR is required — the KYC/liveness signer");
  const attestor = requireChecksummed("ATTESTOR", ATTESTOR);
  if (attestor === ethers.ZeroAddress) throw new Error("ATTESTOR must be non-zero");

  if (isMainnet && !process.env.DEPLOY_OWNER) {
    throw new Error(
      "DEPLOY_OWNER is required on mainnet — pass the blio Safe. Defaulting to the " +
        "deployer EOA would hand limits/products/pause to a hot key."
    );
  }
  if (process.env.DEPLOY_OWNER) requireChecksummed("DEPLOY_OWNER", DEPLOY_OWNER);

  if (isMainnet && (await ethers.provider.getCode(DEPLOY_OWNER)) === "0x") {
    throw new Error(
      `DEPLOY_OWNER ${DEPLOY_OWNER} has no code on mainnet — it is an EOA. Pass the blio Safe.`
    );
  }
  if (isMainnet && (await ethers.provider.getCode(recipient)) === "0x") {
    throw new Error(`RECIPIENT_ADDR ${recipient} has no code on mainnet — pass the blio Safe.`);
  }

  for (const [label, addr] of [
    ["Diamond", DIAMOND_ADDRESS],
    ["USDC", USDC_ADDRESS],
  ] as const) {
    const code = await ethers.provider.getCode(addr);
    if (code === "0x") throw new Error(`${label} ${addr} has NO CODE on chain ${chainId}`);
    console.log(`✅ ${label}: ${addr} (${(code.length - 2) / 2} bytes)`);
  }

  const token = new ethers.Contract(USDC_ADDRESS, ERC20_ABI, ethers.provider);
  try {
    const [symbol, decimals] = await Promise.all([token.symbol(), token.decimals()]);
    console.log(`   settlement token: ${symbol}, ${decimals} decimals`);
    if (Number(decimals) !== 6)
      throw new Error(`settlement token has ${decimals} decimals — limits assume 6`);
  } catch (e) {
    if (isMainnet) throw e;
    warn(`could not read token metadata: ${(e as Error).message}`);
  }

  console.log("\nConfig:");
  console.log(
    `  recipientAddr:    ${recipient}${recipient === deployer.address ? "  (⚠️ DEPLOYER EOA — use a Safe)" : ""}`
  );
  console.log(
    `  owner:            ${DEPLOY_OWNER}${DEPLOY_OWNER === deployer.address ? "  (⚠️ DEPLOYER EOA — use a Safe)" : ""}`
  );
  console.log(`  attestor:         ${attestor}`);
  console.log(`  daily tx count:   ${DAILY_TX_COUNT_LIMIT}`);
  for (const l of DEFAULT_LIMITS) {
    console.log(`  limit ${l.label}: ${l.limit / 1_000_000n} USDC`);
  }

  if (BigInt(DAILY_TX_COUNT_LIMIT) === 0n) throw new Error("DAILY_TX_COUNT_LIMIT must be > 0");
  if (BigInt(DAILY_TX_COUNT_LIMIT) > 5n) throw new Error("DAILY_TX_COUNT_LIMIT must be <= 5");

  if (DRY_RUN) {
    console.log("\n✅ DRY_RUN: preflight passed. Nothing deployed.");
    return;
  }

  console.log("\nDeploying BlioCheckoutIntegrator…");
  const Integ = await ethers.getContractFactory("BlioCheckoutIntegrator");
  const integrator = await Integ.deploy(
    DIAMOND_ADDRESS,
    USDC_ADDRESS,
    recipient,
    DEPLOY_OWNER,
    BigInt(DAILY_TX_COUNT_LIMIT),
    attestor
  );
  await integrator.deploymentTransaction()?.wait(2);
  const integratorAddr = await integrator.getAddress();
  const proxyImpl = await integrator.proxyImpl();
  console.log("  BlioCheckoutIntegrator:", integratorAddr);
  console.log("  proxyImpl:             ", proxyImpl);

  const onchainDaily = await integrator.dailyTxCountLimit();
  if (onchainDaily !== BigInt(DAILY_TX_COUNT_LIMIT)) {
    throw new Error(`dailyTxCountLimit is ${onchainDaily}, expected ${DAILY_TX_COUNT_LIMIT}`);
  }
  for (const l of DEFAULT_LIMITS) {
    const onchain = await integrator.limitFor(l.currency, l.tier);
    if (onchain !== l.limit) {
      throw new Error(`${l.label} limit is ${onchain}, expected ${l.limit}`);
    }
  }
  console.log("  limits:           20/100 (INR), 50/200 (other) — verified on-chain");

  let cfg = null;
  if (REGISTER) {
    console.log("\nRegistering on the Diamond (usdcThroughIntegrator=false)…");
    const b2b = new ethers.Contract(DIAMOND_ADDRESS, REGISTER_ABI, deployer);
    const before = await getIntegratorConfig(ethers.provider, DIAMOND_ADDRESS, integratorAddr);
    if (
      before.proxyImpl !== ethers.ZeroAddress &&
      before.proxyImpl.toLowerCase() !== proxyImpl.toLowerCase()
    ) {
      throw new Error(`proxyImpl already locked to ${before.proxyImpl}; refusing to re-register`);
    }
    const tx = await b2b.registerIntegrator(integratorAddr, false, proxyImpl, false);
    await tx.wait(1);
    console.log("  registerIntegrator tx:", tx.hash);

    cfg = await getIntegratorConfig(ethers.provider, DIAMOND_ADDRESS, integratorAddr);
    console.log(
      `  config: isActive=${cfg.isActive} usdcThroughIntegrator=${cfg.usdcThroughIntegrator} ` +
        `cancelCallbackEnabled=${cfg.cancelCallbackEnabled} proxyImpl=${cfg.proxyImpl}`
    );
    if (!cfg.isActive || cfg.usdcThroughIntegrator !== false) {
      throw new Error("unexpected integrator config after registration");
    }
    if (cfg.cancelCallbackEnabled !== false) {
      throw new Error("cancelCallbackEnabled must stay false");
    }
    if (cfg.proxyImpl.toLowerCase() !== proxyImpl.toLowerCase()) {
      throw new Error("registered proxyImpl does not match the deployed one");
    }
  } else {
    console.log(
      "\nSkipping registration (default). The p2p admin must register this address with " +
        "usdcThroughIntegrator=false and cancelCallbackEnabled=false."
    );
    try {
      cfg = await getIntegratorConfig(ethers.provider, DIAMOND_ADDRESS, integratorAddr);
    } catch (e) {
      warn(`could not read the integrator config: ${(e as Error).message}`);
    }
  }

  if (cfg && cfg.usdcThroughIntegrator) {
    warn("usdcThroughIntegrator is NOT false — settlement would route to the integrator");
  }

  const code = await ethers.provider.getCode(integratorAddr);
  console.log("\n=== blio deployment ===");
  console.log(`BlioCheckoutIntegrator: ${integratorAddr}`);
  console.log(`proxyImpl:              ${proxyImpl}`);
  console.log(`bytecode hash:          ${ethers.keccak256(code)}`);

  console.log("\n--- blio app .env ---");
  console.log(`NEXT_PUBLIC_P2P_INTEGRATOR=${integratorAddr}`);
  console.log(`NEXT_PUBLIC_P2P_USDC=${USDC_ADDRESS}`);
  console.log(`NEXT_PUBLIC_P2P_CHAIN_ID=${chainId}`);

  const verifyNetwork = isMainnet ? "base" : "baseSepolia";
  const verifyArgs = `${DIAMOND_ADDRESS} ${USDC_ADDRESS} ${recipient} ${DEPLOY_OWNER} ${DAILY_TX_COUNT_LIMIT} ${attestor}`;
  console.log("\n--- verify ---");
  console.log(`npx hardhat verify --network ${verifyNetwork} ${integratorAddr} ${verifyArgs}`);
  console.log(
    `npx hardhat verify --network ${verifyNetwork} --verifier blockscout ` +
      `--verifier-url ${isMainnet ? "https://base.blockscout.com/api/" : "https://base-sepolia.blockscout.com/api/"} ` +
      `${integratorAddr} ${verifyArgs}`
  );
}

main()
  .then(() => process.exit(0))
  .catch((e) => {
    console.error(e);
    process.exit(1);
  });
