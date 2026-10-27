// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import { IP2PIntegrator } from "../../interfaces/IP2PIntegrator.sol";
import { IB2BGateway } from "../../interfaces/IB2BGateway.sol";
import { UserProxy } from "../../base/UserProxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title BlioCheckoutIntegrator
 * @notice Consumer checkout for blio.me Premium (local fiat in, USDC on Base out).
 *
 *         ── What it sells ─────────────────────────────────────────────────
 *         Digital subscriptions ("products"): the integrator holds a USDC
 *         price per `productId` (monthly / yearly Premium). The user pays in
 *         local fiat (Pago Movil, PIX, SPEI, ...) off-chain; on settlement the
 *         Diamond pays USDC to `treasury`.
 *
 *         ── Where the money goes (no custody) ─────────────────────────────
 *         `recipientAddr` is pinned to the immutable `treasury` (the blio Safe)
 *         and the integrator is registered with `usdcThroughIntegrator = false`,
 *         so the Diamond settles USDC DIRECTLY to that Safe. There is no vault
 *         and no affiliate split: every settlement is a single transfer. This
 *         contract never holds user funds at any point, which is why it has no
 *         withdrawal path for orders and only a stray-token `sweepUsdc`
 *         recovery hatch. blio's backend watches completion events and grants
 *         Premium off-chain.
 *
 *         ── Delivery is off-chain ──────────────────────────────────────────
 *         There is no on-chain `ICheckoutClient`: entitlement is a database
 *         row in blio, credited from `BlioOrderCompleted`. The integrator's
 *         on-chain job is the protocol lifecycle (validate -> complete /
 *         cancel) and emitting the event blio consumes.
 */
contract BlioCheckoutIntegrator is IP2PIntegrator, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Buyer verification tier. `None` means no attestation and gets a
    ///         zero limit — the contract fails closed until the user submits a
    ///         valid attestation (see `submitLivenessAttestation`).
    enum Tier {
        None,
        Liveness,
        Passport
    }

    // ─── Errors ───────────────────────────────────────────────────────

    error OnlyDiamond();
    error InvalidAddress();
    error InvalidQuantity();
    error ProductNotFound();
    error ProductInactive();
    error AmountExceedsLimit();
    error DailyCountExceeded();
    error ContractPaused();
    error OrderValidationMissing();
    error OrderIdAlreadyUsed();
    error RenounceDisabled();
    /// @notice An owner-settable limit was set above its immutable ceiling.
    error CapExceedsCeiling();
    error InvalidTier();

    // KYC / attestation
    /// @notice The buyer has no attestation; the checkout is closed to them.
    error NotAttested();
    /// @notice The attestation's claim deadline has already passed.
    error AttestationExpired();
    /// @notice The nullifier was already consumed by a previous attestation.
    error NullifierUsed();
    /// @notice The signature did not recover to the immutable attestor.
    error InvalidSignature();
    /// @notice An attestation can only raise the tier, never lower it.
    error TierDowngrade();

    // ─── Events ───────────────────────────────────────────────────────

    event ProductPriceSet(uint256 indexed productId, uint256 price);
    event ProductActiveSet(uint256 indexed productId, bool active);
    event TxLimitUpdated(bytes32 indexed currency, Tier indexed tier, uint256 limit);
    event DailyTxCountLimitUpdated(uint256 count);
    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event UserProxyDeployed(address indexed user, address proxy);
    event UsdcSwept(address indexed to, uint256 amount);

    /// @notice A buyer's verification tier was recorded from a valid attestor
    ///         signature. `nullifier` is single-use (Sybil resistance).
    event AttestationSubmitted(address indexed user, uint8 indexed tier, bytes32 nullifier);

    /// @notice Emitted for every accepted placement so the widget / backend can
    ///         read the product metadata from a single receipt.
    event BlioOrderCreated(
        uint256 indexed orderId,
        address indexed user,
        uint256 productId,
        uint256 quantity,
        uint256 usdcAmount
    );

    /// @notice The signal blio's backend consumes to grant Premium.
    event BlioOrderCompleted(
        uint256 indexed orderId,
        address indexed user,
        uint256 productId,
        uint256 quantity,
        uint256 usdcAmount
    );

    event BlioOrderCancelled(uint256 indexed orderId, address indexed user);

    /// @notice A completion that does not match the recorded order — most
    ///         importantly when the Diamond routed USDC somewhere other than
    ///         `treasury` (the on-chain signature of a mis-registration).
    event SettlementRoutingAnomaly(
        uint256 indexed orderId,
        address expectedUser,
        address callbackUser,
        uint256 callbackAmount,
        address callbackRecipient
    );

    // ─── Immutables ───────────────────────────────────────────────────

    address public immutable diamond;
    IERC20 public immutable usdc;
    /// @notice Canonical `UserProxy` master every per-user clone deploys from.
    ///         Pinned on the Diamond at registration and set-once there.
    address public immutable proxyImpl;
    /// @notice Where the Diamond settles the USDC (the blio Safe). Never this
    ///         contract, and never an intermediate vault.
    address public immutable treasury;
    /// @notice Signer of the KYC/liveness attestations. Immutable: rotating it
    ///         requires a redeploy, which is the point — no owner key can mint
    ///         tiers or rewrite trust after the fact.
    address public immutable attestor;

    // ─── Immutable policy ceilings ────────────────────────────────────
    // Compiled into the bytecode. The constructor and every owner setter are
    // bounded by these, so no limit can ever exceed its ceiling — not by a
    // compromised owner key. Movement below a ceiling is free in both
    // directions.
    uint256 public constant MAX_DAILY_TX_COUNT_LIMIT = 5; // placements/user/day

    /// @notice Per-tx ceilings by currency class and verification tier
    ///         (6 decimals). INR is deliberately tighter than the rest.
    uint256 public constant MAX_TX_LIMIT_INR_LIVENESS = 20e6; // $20
    uint256 public constant MAX_TX_LIMIT_INR_PASSPORT = 100e6; // $100
    uint256 public constant MAX_TX_LIMIT_OTHER_LIVENESS = 50e6; // $50
    uint256 public constant MAX_TX_LIMIT_OTHER_PASSPORT = 200e6; // $200

    bytes32 public constant INR_CURRENCY = bytes32("INR");
    /// @notice Wildcard bucket every non-INR currency normalizes to.
    bytes32 public constant OTHER_CURRENCY = bytes32(0);

    // ─── EIP-712 constants ────────────────────────────────────────────

    /// @dev keccak256("Attestation(address user,uint8 tier,bytes32 nullifier,uint256 deadline)")
    bytes32 private constant _ATTESTATION_TYPEHASH =
        keccak256("Attestation(address user,uint8 tier,bytes32 nullifier,uint256 deadline)");
    bytes32 private constant _EIP712_DOMAIN_TYPEHASH =
        keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );
    bytes32 private constant _DOMAIN_NAME = keccak256(bytes("BlioCheckoutIntegrator"));
    bytes32 private constant _DOMAIN_VERSION = keccak256(bytes("1"));

    // ─── Configurable limits ──────────────────────────────────────────

    /// @dev Effective per-tx USDC cap by normalized currency and tier
    ///      (6 decimals). Initialized to the immutable ceilings in the
    ///      constructor; every owner write is bounded by them.
    mapping(bytes32 => mapping(Tier => uint256)) private _limitFor;
    /// @notice Placements allowed per user per UTC day.
    uint256 public dailyTxCountLimit;
    bool public paused;

    /// @notice Buyer verification tier, written only by a valid attestation.
    ///         `None` is the default and grants a zero limit.
    mapping(address => Tier) public tierOf;
    /// @notice Timestamp of the last accepted attestation for each buyer.
    mapping(address => uint256) public attestedAt;
    /// @notice Per-(tenant, human) Sybil nullifiers already consumed. Once a
    ///         nullifier is used it can never be replayed, even for another
    ///         tier or another wallet.
    mapping(bytes32 => bool) public usedNullifier;

    // ─── Products ─────────────────────────────────────────────────────

    /// @notice USDC price per unit of `productId` (6 decimals). 0 = unknown.
    mapping(uint256 => uint256) public productPrice;
    /// @notice Whether a product can be purchased. Lets the owner retire one
    ///         without deleting its price history.
    mapping(uint256 => bool) public productActive;

    // ─── Order state ──────────────────────────────────────────────────

    struct Session {
        address user; // 20 bytes
        bool fulfilled; //  1 byte — packs with user
        bool cancelled; //  1 byte — packs with user
        uint256 productId;
        uint256 quantity;
        uint256 usdcAmount;
    }

    mapping(uint256 => Session) public sessions;
    mapping(address => mapping(uint256 => uint256)) public userDailyCount;

    /// @dev Binds the Diamond's synchronous `validateOrder` to the placement
    ///      this contract is executing right now, so only the exact
    ///      (user, amount, currency) tuple in flight can validate.
    struct PendingPlacement {
        address user;
        uint256 amount;
        bytes32 currency;
        bool validated;
    }

    PendingPlacement private _pendingPlacement;

    // ─── Modifiers ────────────────────────────────────────────────────

    modifier onlyDiamond() {
        if (msg.sender != diamond) revert OnlyDiamond();
        _;
    }

    // ─── Constructor ──────────────────────────────────────────────────

    /**
     * @param _diamond      P2P Diamond proxy for the target network.
     * @param _usdc         USDC the Diamond settles in on that network.
     * @param _treasury     Destination of every settlement (the blio Safe).
     * @param _owner        Operator key (a multisig): limits, products, pause.
     *                      Transferable two-step via `transferOwnership` /
     *                      `acceptOwnership`.
     * @param _dailyTxCount Placements per user per day (max 5).
     * @param _attestor     Signer of the KYC/liveness attestations. Immutable:
     *                      must be non-zero, otherwise no buyer could ever be
     *                      attested and the checkout would be permanently shut.
     */
    constructor(
        address _diamond,
        address _usdc,
        address _treasury,
        address _owner,
        uint256 _dailyTxCount,
        address _attestor
    ) Ownable(_owner) {
        if (
            _diamond == address(0) ||
            _usdc == address(0) ||
            _treasury == address(0) ||
            _owner == address(0) ||
            _attestor == address(0)
        ) revert InvalidAddress();
        if (_dailyTxCount == 0) revert InvalidQuantity();
        if (_dailyTxCount > MAX_DAILY_TX_COUNT_LIMIT) revert CapExceedsCeiling();

        diamond = _diamond;
        usdc = IERC20(_usdc);
        treasury = _treasury;
        attestor = _attestor;
        dailyTxCountLimit = _dailyTxCount;

        // Seed the whole matrix at its immutable ceiling. Non-INR currencies
        // share the OTHER_CURRENCY bucket, so one write covers "resto".
        _limitFor[INR_CURRENCY][Tier.Liveness] = MAX_TX_LIMIT_INR_LIVENESS;
        _limitFor[INR_CURRENCY][Tier.Passport] = MAX_TX_LIMIT_INR_PASSPORT;
        _limitFor[OTHER_CURRENCY][Tier.Liveness] = MAX_TX_LIMIT_OTHER_LIVENESS;
        _limitFor[OTHER_CURRENCY][Tier.Passport] = MAX_TX_LIMIT_OTHER_PASSPORT;

        proxyImpl = address(new UserProxy());
    }

    // ─── Admin ────────────────────────────────────────────────────────

    function setProductPrice(uint256 productId, uint256 price) external onlyOwner {
        productPrice[productId] = price;
        emit ProductPriceSet(productId, price);
    }

    function setProductActive(uint256 productId, bool active) external onlyOwner {
        productActive[productId] = active;
        emit ProductActiveSet(productId, active);
    }

    function setTxLimit(bytes32 currency, Tier tier, uint256 limit) external onlyOwner {
        if (tier == Tier.None) revert InvalidTier();
        if (limit == 0) revert InvalidQuantity();
        if (limit > maxTxLimitFor(currency, tier)) revert CapExceedsCeiling();
        bytes32 key = normalizeCurrency(currency);
        _limitFor[key][tier] = limit;
        emit TxLimitUpdated(currency, tier, limit);
    }

    function setDailyTxCountLimit(uint256 count) external onlyOwner {
        if (count == 0) revert InvalidQuantity();
        if (count > MAX_DAILY_TX_COUNT_LIMIT) revert CapExceedsCeiling();
        dailyTxCountLimit = count;
        emit DailyTxCountLimitUpdated(count);
    }

    function pause() external onlyOwner {
        if (paused) return;
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        if (!paused) return;
        paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Disabled: burning ownership would permanently disable the
    ///         limits, product, pause and recovery levers.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    /// @notice Recover USDC that should never sit here. By construction every
    ///         settlement routes to `treasury`, so a non-zero balance means a
    ///         stray transfer or a mis-registration.
    function sweepUsdc(address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert InvalidAddress();
        usdc.safeTransfer(to, amount);
        emit UsdcSwept(to, amount);
    }

    // ─── Attestations ─────────────────────────────────────────────────

    /**
     * @notice Record the verification tier the attestor signed for `user`.
     *
     * @dev    The signature is an EIP-712 `Attestation(address user,uint8 tier,
     *         bytes32 nullifier,uint256 deadline)` under the domain
     *         `("BlioCheckoutIntegrator", "1", block.chainid, address(this))`.
     *         It may be submitted by anyone (a relayer can pay the gas); the
     *         signature — not `msg.sender` — authorizes the grant.
     *
     *         `deadline` is a claim-freshness bound only, mirroring the
     *         investabl-challenge pattern: it stops a stale signature from
     *         being redeemed much later, but the tier itself does not expire.
     *         The nullifier is single-use, so a grant can never be re-claimed.
     *
     *         Tiers are monotonic: an attestation can only raise the buyer's
     *         level. An attempt to go back down (Passport -> Liveness) reverts
     *         with `TierDowngrade` rather than being silently ignored, so a
     *         mis-ordered batch is visible to the caller.
     *
     * @param user      Buyer the attestation is for.
     * @param tier      1 = Liveness, 2 = Passport. Anything else reverts.
     * @param nullifier Per-(tenant, human) Sybil nullifier from the service.
     * @param deadline  Unix seconds; the claim must land at or before this.
     * @param signature 65-byte secp256k1 signature (r ‖ s ‖ v) from `attestor`.
     */
    function submitLivenessAttestation(
        address user,
        uint8 tier,
        bytes32 nullifier,
        uint256 deadline,
        bytes calldata signature
    ) external {
        if (user == address(0)) revert InvalidAddress();
        if (block.timestamp > deadline) revert AttestationExpired();
        if (tier != uint8(Tier.Liveness) && tier != uint8(Tier.Passport)) revert InvalidTier();
        if (usedNullifier[nullifier]) revert NullifierUsed();

        bytes32 digest = _attestationDigest(user, tier, nullifier, deadline);
        if (_recover(digest, signature) != attestor) revert InvalidSignature();

        if (tier < uint8(tierOf[user])) revert TierDowngrade();

        usedNullifier[nullifier] = true;
        tierOf[user] = Tier(tier);
        attestedAt[user] = block.timestamp;

        emit AttestationSubmitted(user, tier, nullifier);
    }

    // ─── User-facing placement ────────────────────────────────────────

    /**
     * @notice Place a checkout order for `quantity` units of `productId`.
     *         Cost = productPrice[productId] * quantity.
     *
     * @dev    The UserProxy is the authenticated caller into the gateway; it is
     *         a thin placement vehicle, never a USDC router (`recipientAddr`
     *         is the treasury).
     */
    function userPlaceOrder(
        uint256 productId,
        uint256 quantity,
        bytes32 currency,
        uint256 circleId,
        string calldata pubKey,
        uint256 preferredPaymentChannelConfigId,
        uint256 fiatAmountLimit
    ) external nonReentrant returns (uint256 orderId) {
        if (paused) revert ContractPaused();
        if (quantity == 0) revert InvalidQuantity();
        if (tierOf[msg.sender] == Tier.None) revert NotAttested();

        uint256 price = productPrice[productId];
        if (price == 0) revert ProductNotFound();
        if (!productActive[productId]) revert ProductInactive();

        uint256 total = price * quantity;

        // Friendly pre-checks; `validateOrder` re-enforces authoritatively.
        uint256 lim = userTxLimitFor(msg.sender, currency);
        if (total > lim) revert AmountExceedsLimit();
        if (userDailyCount[msg.sender][block.timestamp / 1 days] >= dailyTxCountLimit) {
            revert DailyCountExceeded();
        }

        _pendingPlacement = PendingPlacement({
            user: msg.sender,
            amount: total,
            currency: currency,
            validated: false
        });

        orderId = _placeOrder(
            total,
            currency,
            circleId,
            pubKey,
            preferredPaymentChannelConfigId,
            fiatAmountLimit
        );

        // The Diamond must have called back through `validateOrder` during the
        // placement. If not, the order was created without passing this gate.
        if (!_pendingPlacement.validated) revert OrderValidationMissing();
        delete _pendingPlacement;

        if (sessions[orderId].user != address(0)) revert OrderIdAlreadyUsed();

        sessions[orderId] = Session({
            user: msg.sender,
            fulfilled: false,
            cancelled: false,
            productId: productId,
            quantity: quantity,
            usdcAmount: total
        });

        emit BlioOrderCreated(orderId, msg.sender, productId, quantity, total);
    }

    function _placeOrder(
        uint256 total,
        bytes32 currency,
        uint256 circleId,
        string calldata pubKey,
        uint256 preferredPaymentChannelConfigId,
        uint256 fiatAmountLimit
    ) internal returns (uint256) {
        address proxy = _ensureProxy(msg.sender);
        bytes memory data = abi.encodeCall(
            IB2BGateway.placeB2BOrder,
            (
                msg.sender,
                total,
                currency,
                treasury,
                pubKey,
                circleId,
                preferredPaymentChannelConfigId,
                fiatAmountLimit
            )
        );
        bytes memory result = UserProxy(proxy).execute(diamond, data, address(usdc), 0);
        return abi.decode(result, (uint256));
    }

    // ─── IP2PIntegrator callbacks ─────────────────────────────────────

    /// @dev The Diamond's synchronous gate during `placeB2BOrder`. Returns
    ///      false (the gateway unwinds) rather than reverting.
    function validateOrder(
        address user,
        uint256 amount,
        bytes32 currency
    ) external onlyDiamond returns (bool allowed) {
        PendingPlacement storage pending = _pendingPlacement;
        if (
            paused ||
            pending.user == address(0) ||
            pending.validated ||
            pending.user != user ||
            pending.amount != amount ||
            pending.currency != currency
        ) return false;

        // Authoritative attestation gate: an unattested buyer can never place an
        // order, and unlike the amount/daily checks this reverts (rather than
        // returning false) so the reason is visible in the receipt.
        if (tierOf[user] == Tier.None) revert NotAttested();

        if (amount == 0) return false;
        if (amount > userTxLimitFor(user, currency)) return false;

        uint256 day = block.timestamp / 1 days;
        uint256 count = userDailyCount[user][day];
        if (count >= dailyTxCountLimit) return false;

        pending.validated = true;
        userDailyCount[user][day] = count + 1;

        return true;
    }

    /**
     * @notice Completion hook. USDC has already been delivered to `treasury` by
     *         the Diamond; this only verifies the callback matches the recorded
     *         order and emits the signal blio's backend consumes.
     *
     * @dev    Never reverts: the gateway wraps this in try/catch, so a revert
     *         would only lose the event and leave the session unfinalised.
     */
    function onOrderComplete(
        uint256 orderId,
        address user,
        uint256 amount,
        address recipientAddr
    ) external onlyDiamond {
        Session storage session = sessions[orderId];
        // A cancellation is NOT terminal in the protocol: an admin can re-open a
        // CANCELLED BUY (dispute path) and complete it. Ignoring `cancelled`
        // here is what lets that reopened order still grant Premium; only an
        // already-fulfilled session is truly done.
        if (session.user == address(0) || session.fulfilled) return;

        // Ask the Diamond how it is routing us, rather than trusting the
        // callback itself: `recipientAddr` is passed unchanged in both routing
        // branches, so it cannot reveal a mis-registered
        // `usdcThroughIntegrator = true` that would strand the USDC here.
        (bool routesHere, bool flagKnown) = _routesThroughIntegrator();
        bool misrouted = flagKnown ? routesHere : usdc.balanceOf(address(this)) >= amount;

        if (
            session.user != user ||
            session.usdcAmount != amount ||
            recipientAddr != treasury ||
            misrouted
        ) {
            emit SettlementRoutingAnomaly(orderId, session.user, user, amount, recipientAddr);
            return;
        }

        session.fulfilled = true;
        emit BlioOrderCompleted(orderId, session.user, session.productId, session.quantity, amount);
    }

    /// @notice Cancellation hook. Marks the session cancelled; it does NOT
    ///         release the daily-count slot reserved in `validateOrder`.
    /// @dev    The counter measures PLACEMENTS, not successful settlements, so
    ///         cancel-and-retry still consumes the user's daily allowance. That
    ///         is also coherent with `cancelCallbackEnabled = false`: the
    ///         gateway may never call this hook at all, so any refund of the
    ///         slot here would be best-effort and gameable. Never reverts
    ///         (best-effort from the gateway's POV).
    function onOrderCancel(uint256 orderId) external onlyDiamond {
        Session storage session = sessions[orderId];
        if (session.user == address(0) || session.fulfilled || session.cancelled) return;

        session.cancelled = true;

        emit BlioOrderCancelled(orderId, session.user);
    }

    // ─── Views ────────────────────────────────────────────────────────

    /// @notice Effective per-tx USDC limit for `user` in `currency`, based on
    ///         the buyer's verification tier.
    function userTxLimitFor(address user, bytes32 currency) public view returns (uint256) {
        Tier tier = _tierOf(user);
        if (tier == Tier.None) return 0;
        return _limitFor[normalizeCurrency(currency)][tier];
    }

    /// @notice Effective per-tx USDC cap stored for `currency` at `tier`.
    function limitFor(bytes32 currency, Tier tier) public view returns (uint256) {
        return _limitFor[normalizeCurrency(currency)][tier];
    }

    /// @notice Widget helper: effective per-tx cap for the caller in `currency`.
    function userTxLimit(bytes32 currency) external view returns (uint256) {
        return userTxLimitFor(msg.sender, currency);
    }

    /// @notice EIP-712 domain separator the attestor signs under.
    function domainSeparator() public view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    _EIP712_DOMAIN_TYPEHASH,
                    _DOMAIN_NAME,
                    _DOMAIN_VERSION,
                    block.chainid,
                    address(this)
                )
            );
    }

    /// @notice Currency class the limit matrix is keyed by: INR is its own
    ///         bucket and every other currency shares `OTHER_CURRENCY`.
    function normalizeCurrency(bytes32 currency) public pure returns (bytes32) {
        return currency == INR_CURRENCY ? INR_CURRENCY : OTHER_CURRENCY;
    }

    /// @notice Immutable ceiling for a (currency, tier) pair.
    function maxTxLimitFor(bytes32 currency, Tier tier) public pure returns (uint256) {
        bool inr = normalizeCurrency(currency) == INR_CURRENCY;
        if (tier == Tier.Passport) {
            return inr ? MAX_TX_LIMIT_INR_PASSPORT : MAX_TX_LIMIT_OTHER_PASSPORT;
        }
        if (tier == Tier.Liveness) {
            return inr ? MAX_TX_LIMIT_INR_LIVENESS : MAX_TX_LIMIT_OTHER_LIVENESS;
        }
        return 0;
    }

    /// @dev The recorded tier, or `None` — which `userTxLimitFor` maps to a zero
    ///      limit, so an unattested buyer cannot transact.
    function _tierOf(address user) internal view returns (Tier) {
        return tierOf[user];
    }

    function getRemainingDailyCount(address user) external view returns (uint256) {
        uint256 count = userDailyCount[user][block.timestamp / 1 days];
        if (count >= dailyTxCountLimit) return 0;
        return dailyTxCountLimit - count;
    }

    function getTodayCount(address user) external view returns (uint256) {
        return userDailyCount[user][block.timestamp / 1 days];
    }

    function getSession(uint256 orderId) external view returns (Session memory) {
        return sessions[orderId];
    }

    /// @notice Predicts the deterministic UserProxy address for `user`.
    function proxyAddress(address user) public view returns (address) {
        return
            Clones.predictDeterministicAddressWithImmutableArgs(
                proxyImpl,
                _proxyArgs(user),
                _salt(user),
                address(this)
            );
    }

    // ─── Internal: proxy helpers ──────────────────────────────────────

    /// @dev `bytes4(keccak256("getIntegratorConfig(address)"))`.
    bytes4 private constant _GET_INTEGRATOR_CONFIG = 0x17353447;

    /// @dev Is the Diamond routing this integrator's settlements to us? Reads
    ///      word 1 (`usdcThroughIntegrator`) raw, so it survives the config
    ///      struct growing fields in the middle.
    function _routesThroughIntegrator() private view returns (bool routes, bool known) {
        (bool ok, bytes memory ret) = diamond.staticcall(
            abi.encodeWithSelector(_GET_INTEGRATOR_CONFIG, address(this))
        );
        if (!ok || ret.length < 64) return (false, false);

        uint256 flag;
        assembly {
            flag := mload(add(ret, 0x40))
        }
        return (flag != 0, true);
    }

    // ─── Internal: EIP-712 attestation verification ───────────────────

    function _attestationDigest(
        address user,
        uint8 tier,
        bytes32 nullifier,
        uint256 deadline
    ) private view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(_ATTESTATION_TYPEHASH, user, tier, nullifier, deadline)
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));
    }

    function _recover(bytes32 digest, bytes calldata sig) private pure returns (address) {
        if (sig.length != 65) revert InvalidSignature();
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }
        // Reject the high-`s` half of each signature (EIP-2): otherwise every
        // signature has a malleated twin that recovers the same signer.
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0)
            revert InvalidSignature();
        if (v != 27 && v != 28) revert InvalidSignature();
        address signer = ecrecover(digest, v, r, s);
        if (signer == address(0)) revert InvalidSignature();
        return signer;
    }

    function _salt(address user) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(user)));
    }

    function _proxyArgs(address user) internal view returns (bytes memory) {
        return abi.encodePacked(user, address(this));
    }

    function _ensureProxy(address user) internal returns (address proxy) {
        proxy = proxyAddress(user);
        if (proxy.code.length == 0) {
            address deployed = Clones.cloneDeterministicWithImmutableArgs(
                proxyImpl,
                _proxyArgs(user),
                _salt(user)
            );
            assert(deployed == proxy);
            emit UserProxyDeployed(user, proxy);
        }
    }
}
