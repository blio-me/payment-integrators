import { ethers } from "hardhat";

/**
 * Register/refresh the blio Premium products (productId 1..4) on the deployed
 * BlioCheckoutIntegrator. Idempotent: it only writes when the on-chain value
 * differs from the target, so it is safe to re-run.
 *
 * Prices match the web/app PLANS (9.99 / 26.99 / 49.99 / 79.99 USDC) and must
 * stay within the integrator's `baseTxLimit` (set to at least 100 USDC in
 * scripts/deploy-blio.ts).
 *
 * setProductPrice/setProductActive are onlyOwner, so the signer MUST be the
 * blio owner Safe (or its delegate).
 *
 * Env (required, no hardcoded address):
 *   INTEGRATOR=0x...  the BlioCheckoutIntegrator deployed for blio
 *
 * Run (Base Sepolia), from payment-integrators/:
 *   INTEGRATOR=0x... npx hardhat run scripts/set-blio-products.ts --network baseSepolia
 */

const INTEGRATOR = process.env.INTEGRATOR || "";

const PRODUCTS: Record<number, bigint> = {
  1: 9_990_000n,
  2: 26_990_000n,
  3: 49_990_000n,
  4: 79_990_000n,
};

const ABI = [
  "function productPrice(uint256) view returns (uint256)",
  "function productActive(uint256) view returns (bool)",
  "function owner() view returns (address)",
  "function setProductPrice(uint256 productId, uint256 price)",
  "function setProductActive(uint256 productId, bool active)",
];

async function main() {
  if (!ethers.isAddress(INTEGRATOR)) {
    throw new Error(`INTEGRATOR env var is missing or not a valid address: "${INTEGRATOR}"`);
  }
  const net = await ethers.provider.getNetwork();
  if (net.chainId !== 84532n && net.chainId !== 8453n) {
    throw new Error(
      `Unsupported chainId ${net.chainId} — expected 84532 (Base Sepolia) or 8453 (Base).`
    );
  }
  const [signer] = await ethers.getSigners();
  const c = new ethers.Contract(INTEGRATOR, ABI, signer);

  const owner: string = await c.owner();
  console.log("chainId    :", net.chainId.toString());
  console.log("integrator :", INTEGRATOR);
  console.log("signer     :", signer.address);
  console.log("owner      :", owner);

  if (owner.toLowerCase() !== signer.address.toLowerCase()) {
    throw new Error(
      "Signer is NOT the integrator owner — setProductPrice/setProductActive are onlyOwner. " +
        "Use the blio owner Safe (or a delegate with the owner key)."
    );
  }

  for (const [idStr, price] of Object.entries(PRODUCTS)) {
    const productId = BigInt(idStr);
    const [currentPrice, active]: [bigint, boolean] = await Promise.all([
      c.productPrice(productId),
      c.productActive(productId),
    ]);

    if (currentPrice !== price) {
      const tx = await c.setProductPrice(productId, price);
      console.log(`product ${idStr}: setProductPrice ${currentPrice} → ${price} (tx ${tx.hash})`);
      await tx.wait(2);
    } else {
      console.log(`product ${idStr}: price already ${price}`);
    }

    if (!active) {
      const tx = await c.setProductActive(productId, true);
      console.log(`product ${idStr}: setProductActive → true (tx ${tx.hash})`);
      await tx.wait(2);
    } else {
      console.log(`product ${idStr}: already active`);
    }
  }

  console.log("\n✓ blio products configured.");
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
