// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title BlioTreasuryVault
 * @notice Immutable settlement destination ("treasury") for BlioCheckoutIntegrator.
 *
 *         The integrator pins this vault ONCE at deploy (`treasury = vault`).
 *         Every settlement lands here as USDC. The real destination — and an
 *         optional affiliate split — live INSIDE the vault and can be changed
 *         at any time by the multisig owner. So:
 *           - the integrator never needs to be redeployed or reconfigured,
 *           - the real treasury wallet is never exposed in the integrator,
 *           - activating an affiliate program is a single `setAffiliate` call.
 */
contract BlioTreasuryVault is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 internal constant MAX_BPS = 10_000;

    /// @notice USDC token settled into this vault.
    IERC20 public immutable usdc;

    /// @notice Real destination of settled funds (the treasury wallet).
    address public recipient;

    /// @notice Optional affiliate receiver + its share (bps of each payout).
    address public affiliate;
    uint16 public affiliateBps;

    /// @notice When paused, `distribute()` is a no-op (funds just accumulate).
    bool public paused;

    event RecipientChanged(address indexed recipient);
    event AffiliateChanged(address indexed affiliate, uint16 bps);
    event PausedSet(bool paused);
    event Distributed(
        address indexed recipient,
        uint256 recipientAmount,
        address indexed affiliate,
        uint256 affiliateAmount
    );
    event Swept(address indexed token, address indexed to, uint256 amount);

    error ZeroAddress();
    error BadBps();
    error IsPaused();
    error RenounceDisabled();

    constructor(address _usdc, address _owner, address _recipient) Ownable(_owner) {
        if (_usdc == address(0) || _owner == address(0) || _recipient == address(0)) {
            revert ZeroAddress();
        }
        usdc = IERC20(_usdc);
        recipient = _recipient;
        emit RecipientChanged(_recipient);
    }

    // ── Owner configuration ────────────────────────────────────────────────

    /// @notice Point payouts at a new treasury wallet.
    function setRecipient(address _recipient) external onlyOwner {
        if (_recipient == address(0)) revert ZeroAddress();
        recipient = _recipient;
        emit RecipientChanged(_recipient);
    }

    /// @notice Enable/disable the affiliate split. `bps` in 1e-4 (e.g. 1000 = 10%).
    function setAffiliate(address _affiliate, uint16 _bps) external onlyOwner {
        if (_bps > MAX_BPS) revert BadBps();
        if (_affiliate == address(0) && _bps != 0) revert ZeroAddress();
        affiliate = _affiliate;
        affiliateBps = _bps;
        emit AffiliateChanged(_affiliate, _bps);
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit PausedSet(_paused);
    }

    // ── Distribution ───────────────────────────────────────────────────────

    /// @notice Forward the whole USDC balance to the configured recipients.
    ///         Permissionless: funds can only ever go to `recipient`/`affiliate`.
    function distribute() external nonReentrant {
        if (paused) revert IsPaused();
        uint256 bal = usdc.balanceOf(address(this));
        if (bal == 0) return;

        uint256 fee = affiliate != address(0) ? (bal * affiliateBps) / MAX_BPS : 0;
        uint256 toRecipient = bal - fee;

        if (toRecipient > 0) usdc.safeTransfer(recipient, toRecipient);
        if (fee > 0) usdc.safeTransfer(affiliate, fee);

        emit Distributed(recipient, toRecipient, affiliate, fee);
    }

    /// @notice Rescue any non-USDC token accidentally sent here.
    function sweep(address token, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) IERC20(token).safeTransfer(to, bal);
        emit Swept(token, to, bal);
    }

    /// @notice Disabled: renouncing would freeze the distribution config.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }
}
