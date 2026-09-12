// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Where every protocol fee lands, and the only place a referral is paid.
/// @dev    No owner, no setter, no sweep. The treasury address is fixed at
///         construction. A referrer is written once by the referred user and can
///         never be changed, so attribution cannot be re-pointed after the fact.
contract FeeRouter {
    using SafeERC20 for IERC20;

    uint16 public constant REFERRAL_BPS = 2_000; // 20% of every inflow
    uint16 private constant BPS = 10_000;

    address public immutable treasury;

    mapping(address user => address referrer) public referrerOf;
    mapping(address token => mapping(address account => uint256 amount)) public claimable;

    event ReferrerSet(address indexed user, address indexed referrer);
    event FeeTaken(address indexed token, address indexed user, uint256 amount, uint256 toReferrer);
    event Claimed(address indexed token, address indexed account, uint256 amount);

    error ZeroAddress();
    error AlreadyReferred();
    error SelfReferral();
    error NothingToClaim();

    constructor(address _treasury) {
        if (_treasury == address(0)) revert ZeroAddress();
        treasury = _treasury;
    }

    /// @notice Claim a referrer. Callable once per address, by the referred user only.
    function setReferrer(address referrer) external {
        if (referrer == address(0)) revert ZeroAddress();
        if (referrer == msg.sender) revert SelfReferral();
        if (referrerOf[msg.sender] != address(0)) revert AlreadyReferred();
        referrerOf[msg.sender] = referrer;
        emit ReferrerSet(msg.sender, referrer);
    }

    /// @notice Pull `amount` of `token` from the caller and credit it.
    /// @param  user the account the fee is attributed to — whose referrer earns the share.
    /// @dev    Caller must have approved this contract. Pull rather than push so the
    ///         accounting cannot be desynced by a bare transfer.
    function take(address token, address user, uint256 amount) external {
        if (amount == 0) return;
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        address ref = referrerOf[user];
        uint256 toRef;
        if (ref != address(0)) {
            toRef = (amount * REFERRAL_BPS) / BPS;
            claimable[token][ref] += toRef;
        }
        claimable[token][treasury] += amount - toRef;

        emit FeeTaken(token, user, amount, toRef);
    }

    /// @notice Withdraw everything owed to the caller in `token`.
    function claim(address token) external returns (uint256 amount) {
        amount = claimable[token][msg.sender];
        if (amount == 0) revert NothingToClaim();
        claimable[token][msg.sender] = 0;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit Claimed(token, msg.sender, amount);
    }
}
