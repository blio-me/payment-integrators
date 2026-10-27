# BlioCheckoutIntegrator

Consumer checkout for **blio.me Premium**. Users pay in **local fiat**
(Pago Móvil, PIX, SPEI, …) and the Diamond settles **USDC on Base** directly
into the blio Safe. Premium itself is granted **off-chain** by blio's backend,
which consumes `BlioOrderCompleted`.

- **Source:** `contracts/integrators/blio/BlioCheckoutIntegrator.sol`
- **Registration:** `usdcThroughIntegrator = false`, `cancelCallbackEnabled = false`
- **Diamond:** `0x4cad6eC90e65baBec9335cAd728DDC610c316368` (Base mainnet) ·
  `0xeb0BB8E3c014D915D9B2df03aBB130a1Fb44beb9` (Base Sepolia)
- **USDC (Base):** `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`
- **Recipient / treasury:** `0xFB25b3BFc8eCEA01eC70763f92fBc8B3079bdf47` (blio Safe)

## Architecture

There is no intermediate vault and no revenue-share layer. Every order pins
`recipientAddr` to the immutable Safe, so the USDC transfer from the Diamond
goes **straight to the Safe** and the integrator never holds user funds.

```
buyer EOA ──userPlaceOrder──▶ BlioCheckoutIntegrator
                                   │  placeB2BOrder(..., recipientAddr = Safe)
                                   ▼
                                 Diamond ──USDC──▶ blio Safe
                                   │
                                   └─ onOrderComplete ──▶ BlioOrderCompleted
                                                              │
                                                              ▼
                                                   blio backend → Premium
```

The on-chain job is only the protocol lifecycle (validate → complete / cancel)
plus emitting the event blio consumes. Entitlement is a database row in blio,
not an on-chain token.

## Products and limits

Products are `productId`s with a USDC price set by the owner
(`setProductPrice`, `setProductActive`). blio uses `productId` 1–4 for its
Premium plans.

Per-transaction ceilings are compiled into the bytecode and seeded in the
constructor. The owner may only tighten them, never raise them:

| Currency class | Tier | Per-tx cap |
| --- | --- | ---: |
| `INR` | Liveness | **20 USDC** |
| `INR` | Passport | **100 USDC** |
| Every other currency | Liveness | **50 USDC** |
| Every other currency | Passport | **200 USDC** |

All non-INR currencies share the `OTHER_CURRENCY` bucket (`bytes32(0)`).

**Daily limit:** `dailyTxCountLimit = 5` **placements per user per UTC day**.
The counter is incremented in `validateOrder`, i.e. when the order is placed,
not when it settles.

## Attestation (KYC gate)

A buyer with no attestation has `Tier.None` and a **zero** limit. The checkout
fails closed: `userPlaceOrder` reverts with `NotAttested` until a valid
signature is submitted.

- **Tiers:** `1 = Liveness`, `2 = Passport`. Grants are monotonic: an
  attestation can raise the tier but never lower it (`TierDowngrade`).
- **Attestor:** an immutable address fixed in the constructor (`ATTESTOR`).
  It is the only key that can authorize a tier. Rotating it requires a
  redeploy — no owner key can mint tiers after the fact.
- **Domain (EIP-712):**
  `EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)`
  with `name = "BlioCheckoutIntegrator"`, `version = "1"`,
  `chainId = block.chainid`, `verifyingContract = <integrator address>`.
  `domainSeparator()` returns it.
- **Type:**
  `Attestation(address user,uint8 tier,bytes32 nullifier,uint256 deadline)`.
- **Submission:** `submitLivenessAttestation(user, tier, nullifier, deadline, signature)`.
  Anyone may submit it (a relayer can pay gas); the signature, not
  `msg.sender`, authorizes the grant.
- **`deadline`:** freshness bound only. The claim must land at or before it;
  the tier itself does not expire.
- **Nullifier:** a per-human Sybil nullifier from the KYC service. It is
  single-use (`usedNullifier`), so the same grant can never be replayed, even
  for another wallet or tier. Reuse reverts with `NullifierUsed`.

Signing sketch (ethers):

```ts
const domain = {
  name: "BlioCheckoutIntegrator",
  version: "1",
  chainId,
  verifyingContract: integrator,
};
const types = {
  Attestation: [
    { name: "user", type: "address" },
    { name: "tier", type: "uint8" },
    { name: "nullifier", type: "bytes32" },
    { name: "deadline", type: "uint256" },
  ],
};
const signature = await attestorSigner.signTypedData(domain, types, {
  user,
  tier: 1,
  nullifier,
  deadline,
});
```

## End-to-end flow

1. **Attestation (off-chain → on-chain).** The KYC/liveness provider issues a
   signed attestation; blio (or a relayer) submits it and the buyer's tier is
   recorded.
2. **Placement.** The widget calls
   `userPlaceOrder(productId, quantity, currency, circleId, pubKey, preferredPaymentChannelConfigId, fiatAmountLimit)`.
   The integrator deploys the buyer's `UserProxy` (CREATE2) and places the order
   through it, with `recipientAddr = Safe`.
3. **Fiat payment.** The buyer pays the merchant off-chain in local currency.
4. **Settlement.** The Diamond transfers USDC **directly to the Safe** and calls
   `onOrderComplete`. The integrator verifies that user, amount and
   `recipientAddr` match the recorded session, then emits
   `BlioOrderCompleted(orderId, user, productId, quantity, usdcAmount)`.
5. **Premium (off-chain).** blio's backend indexes `BlioOrderCompleted` and
   credits Premium in its database.

There is **no on-chain receipt**. `BlioOrderCreated` records intent; only
`BlioOrderCompleted` grants entitlement. If the Diamond reports settlement
through the integrator instead of the Safe, the contract emits
`SettlementRoutingAnomaly` and deliberately does **not** emit the completion
event — reconcile manually and alert.

## Cancellation and the daily quota

`cancelCallbackEnabled` stays **`false`**. The Diamond only calls
`onOrderCancel` when that flag is enabled, and blio does not need it:

- The daily counter measures **placements**, so a cancellation or expiry does
  **not** release the slot. Cancel-and-retry still consumes the buyer's
  allowance. Releasing it in `onOrderCancel` would be best-effort at most
  (the callback may never arrive) and gameable.
- An admin can re-open a CANCELLED order and complete it (dispute path). The
  contract handles that: `onOrderComplete` ignores the `cancelled` flag and
  still emits `BlioOrderCompleted`, so a reopened order can grant Premium.
- `onOrderCancel` is idempotent and never reverts; a missing callback only
  affects off-chain bookkeeping, not entitlement.

## Mainnet requirements

- **Owner and treasury = blio Safe.** `owner` controls products, limits and
  pause; `treasury` receives settlement. Both should be the Safe
  (`0xFB25…`). The deploy script refuses to default the owner to the deployer
  EOA on mainnet.
- **Attestor.** A non-zero, dedicated signer must be provided via `ATTESTOR`.
  It is immutable per deployment.
- **On-chain verification.** Verify the integrator source (Blockscout or
  Etherscan) with the exact constructor arguments, then read
  `diamond()`, `usdc()`, `treasury()`, `attestor()`, `proxyImpl()`,
  `dailyTxCountLimit()` and the four `limitFor()` entries and confirm they
  match the policy. Confirm the Diamond registration is
  `usdcThroughIntegrator = false` and `cancelCallbackEnabled = false`.
- **Widget fraud filter.** INR BUY orders are not auto-approved: the pay page
  must pass the p2p fraud-screening prop and an approved screening record keyed
  by order id. Use the customer's ephemeral key (the same one used for
  `pubKey`) to sign the screening message, and allow the pay-page origin in the
  fraud engine's CORS. Testnet demos do not enforce this.
- **Relay `pubKey`.** Every placement carries the P2P `pubKey` used for
  merchant communication. The relay must supply a valid, stable key (it is
  forwarded opaquely by the contract and read by the merchant), and the buyer's
  `user` must remain the account that can sign `paidBuyOrder` / `cancelOrder`.
- **Registration is admin-gated.** `registerIntegrator` is
  `onlySuperAdmin`; the p2p admin performs it, or the deployer may use
  `--register` when it holds that role.

## Deploy

```bash
# Deploy only (registration left to the p2p admin):
RECIPIENT_ADDR=0xFB25b3BFc8eCEA01eC70763f92fBc8B3079bdf47 \
ATTESTOR=0x... DEPLOY_OWNER=0xFB25b3BFc8eCEA01eC70763f92fBc8B3079bdf47 \
  npx hardhat run scripts/deploy-blio.ts --network baseSepolia   # then --network base

# Deploy and register (requires the Diamond super-admin key):
RECIPIENT_ADDR=0x... ATTESTOR=0x... DEPLOY_OWNER=0x... \
  npx hardhat run scripts/deploy-blio.ts --network base --register
```

Defaults: `DAILY_TX_COUNT_LIMIT=5` and the 20/50/100/200 matrix. On Base
mainnet `RECIPIENT_ADDR` defaults to the blio Safe. `TREASURY` is accepted as a
legacy alias. The script verifies the limits on-chain after deployment, warns
if `usdcThroughIntegrator` is ever observed as non-false, and prints both the
Etherscan and Blockscout verification commands.

Then configure the products (idempotent, `onlyOwner`):

```bash
INTEGRATOR=0x... npx hardhat run scripts/set-blio-products.ts --network base
```

## Off-chain integration

- Index `BlioOrderCompleted` and grant Premium exactly once per `orderId`.
  Do not grant on `BlioOrderCreated`.
- Alert on `SettlementRoutingAnomaly`; it means the session was not fulfilled
  and no completion event follows.
- Tolerate missing `BlioOrderCancelled`: the Diamond may never emit it with
  `cancelCallbackEnabled = false`.

## What changed from the previous version

- The **intermediate treasury contract** (vault) was removed. The Safe is the
  immutable `treasury`, so settlement is a single direct USDC transfer.
- **Revenue-share / partner split** logic was removed, along with its
  parameters and deploy steps.
- No order funds ever pass through the integrator or the `UserProxy`; the only
  USDC recovery lever is for stray tokens, not a withdrawal path.
- The deploy script no longer configures vault or partner addresses, and
  defaults to the 20/50/100/200 limits with 5 placements per day.
