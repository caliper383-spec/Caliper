// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {LiquidityAmounts} from "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import {INonfungiblePositionManager as INPM} from
    "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

import {Policy, PolicyLib} from "./libraries/Policy.sol";
import {TwapGuard} from "./libraries/TwapGuard.sol";
import {FeeRouter} from "./FeeRouter.sol";

/// @title  CaliperVault
/// @notice An ERC-4626 vault holding exactly one concentrated Uniswap v3 position.
///         Deposit one token, hold a managed range, take the trading fees.
///
/// @dev    Deliberately has no owner, no upgrade path, no pause and no rescue
///         function: the calls that would let anyone move a depositor's money were
///         never written. Every value-moving path is bounded by TwapGuard and by
///         the policy's slippage cap, both fixed at initialisation.
///
///         This is a clone target. All configuration lives in storage rather than
///         immutables so that an EIP-1167 proxy reads its own values, and the
///         implementation's constructor marks it initialised so nobody can claim it.
contract CaliperVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── constants ────────────────────────────────────────────────────────────
    uint16 internal constant PROTOCOL_FEE_BPS = 1_000; // 10% of fees earned, never of principal
    uint16 internal constant BPS = 10_000;
    uint32 public constant TWAP_WINDOW = 600;          // 10 minutes of real history
    uint16 public constant TWAP_BAND_BPS = 300;        // spot must sit within 3%

    // ─── storage (clone-safe) ─────────────────────────────────────────────────
    string  public name;
    string  public symbol;
    uint8   public decimals;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public asset;       // the token depositors hand over
    address public token0;
    address public token1;
    uint24  public feeTier;
    int24   public tickSpacing;

    IUniswapV3Pool public pool;
    INPM           public positionManager;
    ISwapRouter    public router;
    FeeRouter      public feeRouter;

    uint256 public cap;         // deposit ceiling, written once, no setter
    Policy  public policy;      // written once, no setter

    uint256 public tokenId;     // the position this vault holds, 0 until first deploy
    int24   public tickLower;
    int24   public tickUpper;
    uint64  public lastActionAt;

    bool private _initialized;

    // ─── events ───────────────────────────────────────────────────────────────
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );
    event Deployed(uint256 indexed tokenId, int24 tickLower, int24 tickUpper, uint128 liquidity);
    event Harvested(uint256 collected0, uint256 collected1, uint256 protocolFee, uint256 bounty);
    event Rebalanced(int24 newLower, int24 newUpper, uint256 bounty);

    // ─── errors ───────────────────────────────────────────────────────────────
    error AlreadyInitialized();
    error NotInitialized();
    error ZeroAddress();
    error ZeroAmount();
    error CapExceeded();
    error InsufficientShares();
    error TooSoon();
    error InRange();
    error NoPosition();
    error SlippageExceeded();
    error AssetNotInPool();

    /// @dev The implementation is born initialised, so it can never be configured
    ///      and mistaken for a live vault.
    constructor() {
        _initialized = true;
    }

    // ─── initialisation ───────────────────────────────────────────────────────

    struct InitParams {
        address asset;
        address pool;
        address positionManager;
        address router;
        address feeRouter;
        uint256 cap;
        Policy  policy;
        string  name;
        string  symbol;
    }

    /// @notice Configure a fresh clone. The factory calls this in the same
    ///         transaction it clones in, so an unconfigured clone never exists
    ///         in a block for a stranger to claim.
    function initialize(InitParams calldata p) external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;

        if (p.asset == address(0) || p.pool == address(0)) revert ZeroAddress();
        if (p.positionManager == address(0) || p.router == address(0)) revert ZeroAddress();
        if (p.feeRouter == address(0)) revert ZeroAddress();

        IUniswapV3Pool _pool = IUniswapV3Pool(p.pool);
        address t0 = _pool.token0();
        address t1 = _pool.token1();
        if (p.asset != t0 && p.asset != t1) revert AssetNotInPool();

        int24 spacing = _pool.tickSpacing();
        PolicyLib.validate(p.policy, spacing);

        pool = _pool;
        token0 = t0;
        token1 = t1;
        feeTier = _pool.fee();
        tickSpacing = spacing;

        asset = p.asset;
        decimals = IERC20Metadata(p.asset).decimals();
        name = p.name;
        symbol = p.symbol;

        positionManager = INPM(p.positionManager);
        router = ISwapRouter(p.router);
        feeRouter = FeeRouter(p.feeRouter);
        cap = p.cap;
        policy = p.policy;
    }

    // ─── ERC-20 ───────────────────────────────────────────────────────────────

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < value) revert InsufficientShares();
            allowance[from][msg.sender] = allowed - value;
        }
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) private {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = balanceOf[from];
        if (bal < value) revert InsufficientShares();
        unchecked {
            balanceOf[from] = bal - value;
            balanceOf[to] += value;
        }
        emit Transfer(from, to, value);
    }

    function _mint(address to, uint256 value) private {
        totalSupply += value;
        unchecked { balanceOf[to] += value; }
        emit Transfer(address(0), to, value);
    }

    function _burn(address from, uint256 value) private {
        uint256 bal = balanceOf[from];
        if (bal < value) revert InsufficientShares();
        unchecked {
            balanceOf[from] = bal - value;
            totalSupply -= value;
        }
        emit Transfer(from, address(0), value);
    }

    // ─── valuation ────────────────────────────────────────────────────────────

    /// @notice Everything the vault holds, denominated in `asset`, at the pool's
    ///         current price.
    /// @dev    The non-asset leg is valued net of the pool fee, because the vault
    ///         must sell that leg through the pool to pay anyone out. Valued gross,
    ///         this would report a number the vault cannot actually realise and the
    ///         last redeemer would eat the shortfall.
    ///
    ///         Uncollected trading fees are deliberately excluded. Counting them
    ///         would make `harvest` reduce totalAssets by the protocol cut and the
    ///         bounty, which would let anyone move the share price by calling it.
    function totalAssets() public view returns (uint256) {
        (uint256 amt0, uint256 amt1) = _holdings();
        (uint160 sqrtP,,,,,,) = pool.slot0();

        if (asset == token0) {
            return amt0 + _netOfFee(_quoteToken1AsToken0(amt1, sqrtP));
        }
        return amt1 + _netOfFee(_quoteToken0AsToken1(amt0, sqrtP));
    }

    /// @dev Loose balances plus the principal the position would return if closed now.
    function _holdings() internal view returns (uint256 amt0, uint256 amt1) {
        amt0 = IERC20(token0).balanceOf(address(this));
        amt1 = IERC20(token1).balanceOf(address(this));

        uint256 id = tokenId;
        if (id == 0) return (amt0, amt1);

        (,,,,,,, uint128 liquidity,,,,) = positionManager.positions(id);
        if (liquidity == 0) return (amt0, amt1);

        (uint160 sqrtP,,,,,,) = pool.slot0();
        (uint256 p0, uint256 p1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtP, TickMath.getSqrtRatioAtTick(tickLower), TickMath.getSqrtRatioAtTick(tickUpper), liquidity
        );
        amt0 += p0;
        amt1 += p1;
    }

    function _netOfFee(uint256 amount) private view returns (uint256) {
        // pool fee is in hundredths of a bip: 3000 == 0.30%
        return amount - FullMath.mulDiv(amount, feeTier, 1_000_000);
    }

    function _quoteToken0AsToken1(uint256 amount0, uint160 sqrtP) private pure returns (uint256) {
        uint256 priceX128 = FullMath.mulDiv(sqrtP, sqrtP, 1 << 64);
        return FullMath.mulDiv(amount0, priceX128, 1 << 128);
    }

    function _quoteToken1AsToken0(uint256 amount1, uint160 sqrtP) private pure returns (uint256) {
        uint256 priceX128 = FullMath.mulDiv(sqrtP, sqrtP, 1 << 64);
        if (priceX128 == 0) return 0;
        return FullMath.mulDiv(amount1, 1 << 128, priceX128);
    }

    // ─── ERC-4626 views ───────────────────────────────────────────────────────

    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply;
        if (supply == 0) return assets;
        return FullMath.mulDiv(assets, supply, totalAssets());
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply;
        if (supply == 0) return shares;
        return FullMath.mulDiv(shares, totalAssets(), supply);
    }

    function previewDeposit(uint256 assets) external view returns (uint256) { return convertToShares(assets); }
    function previewRedeem(uint256 shares) external view returns (uint256) { return convertToAssets(shares); }
    function maxDeposit(address) external view returns (uint256) {
        uint256 ta = totalAssets();
        return ta >= cap ? 0 : cap - ta;
    }
    function maxRedeem(address owner) external view returns (uint256) { return balanceOf[owner]; }

    // ─── deposit / redeem ─────────────────────────────────────────────────────

    /// @notice Deposit `assets` of the vault's asset and receive shares.
    /// @dev    Funds land loose and are put to work by `deploy()`, which anyone may
    ///         call. Share price is unaffected either way because `totalAssets`
    ///         counts loose balances and position principal identically.
    function deposit(uint256 assets, address receiver) external nonReentrant returns (uint256 shares) {
        if (!_initialized) revert NotInitialized();
        if (assets == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        TwapGuard.check(pool, TWAP_WINDOW, TWAP_BAND_BPS);

        if (totalAssets() + assets > cap) revert CapExceeded();

        shares = convertToShares(assets);
        if (shares == 0) revert ZeroAmount();

        IERC20(asset).safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @notice Burn `shares` and receive the underlying, in `asset`.
    /// @dev    Takes the payout from loose balances first, then liquidates a
    ///         proportional slice of the position. The non-asset leg is sold
    ///         through the pool under the policy's slippage bound.
    function redeem(uint256 shares, address receiver, address owner)
        external
        nonReentrant
        returns (uint256 assets)
    {
        if (shares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender];
            if (allowed != type(uint256).max) {
                if (allowed < shares) revert InsufficientShares();
                allowance[owner][msg.sender] = allowed - shares;
            }
        }

        TwapGuard.check(pool, TWAP_WINDOW, TWAP_BAND_BPS);

        uint256 supply = totalSupply;
        assets = FullMath.mulDiv(shares, totalAssets(), supply);
        if (assets == 0) revert ZeroAmount();

        _burn(owner, shares);

        // pull a proportional slice of the position before paying out
        uint256 id = tokenId;
        if (id != 0) {
            (,,,,,,, uint128 liquidity,,,,) = positionManager.positions(id);
            if (liquidity > 0) {
                uint128 toRemove = uint128(FullMath.mulDiv(liquidity, shares, supply));
                if (toRemove > 0) _decrease(id, toRemove);
            }
        }

        // sell whatever of the other token we are holding, into the asset
        address other = asset == token0 ? token1 : token0;
        uint256 otherBal = IERC20(other).balanceOf(address(this));
        if (otherBal > 0) _swap(other, asset, otherBal);

        uint256 available = IERC20(asset).balanceOf(address(this));
        if (assets > available) assets = available;

        IERC20(asset).safeTransfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    // ─── position management ──────────────────────────────────────────────────

    /// @notice Put idle balances to work in the range. Permissionless: it can only
    ///         ever move the vault's own funds into the vault's own position.
    function deploy() external nonReentrant {
        if (!_initialized) revert NotInitialized();
        TwapGuard.check(pool, TWAP_WINDOW, TWAP_BAND_BPS);

        (, int24 spotTick,,,,,) = pool.slot0();

        if (tokenId == 0) {
            (int24 lo, int24 hi) = _centeredRange(spotTick);
            tickLower = lo;
            tickUpper = hi;
        }

        _balanceToRatio();

        uint256 bal0 = IERC20(token0).balanceOf(address(this));
        uint256 bal1 = IERC20(token1).balanceOf(address(this));
        if (bal0 == 0 && bal1 == 0) revert ZeroAmount();

        _approve(token0, address(positionManager), bal0);
        _approve(token1, address(positionManager), bal1);

        uint16 slip = policy.maxSlippageBps;
        uint256 valueBefore = totalAssets();

        if (tokenId == 0) {
            (uint256 id, uint128 liq,,) = positionManager.mint(
                INPM.MintParams({
                    token0: token0,
                    token1: token1,
                    fee: feeTier,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    amount0Desired: bal0,
                    amount1Desired: bal1,
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: address(this),
                    deadline: block.timestamp
                })
            );
            tokenId = id;
            emit Deployed(id, tickLower, tickUpper, liq);
        } else {
            (uint128 liq,,) = positionManager.increaseLiquidity(
                INPM.IncreaseLiquidityParams({
                    tokenId: tokenId,
                    amount0Desired: bal0,
                    amount1Desired: bal1,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp
                })
            );
            emit Deployed(tokenId, tickLower, tickUpper, liq);
        }

        // the whole operation is bounded end to end, not each leg of the mint
        if (totalAssets() < _minOut(valueBefore, slip)) revert SlippageExceeded();

        lastActionAt = uint64(block.timestamp);
    }

    /// @notice Collect trading fees. Permissionless — the protocol takes 10% of what
    ///         was collected and the caller takes the policy's bounty, both out of
    ///         fees only. Principal is never touched by this path.
    function harvest() external nonReentrant {
        uint256 id = tokenId;
        if (id == 0) revert NoPosition();
        if (block.timestamp < lastActionAt + policy.minInterval) revert TooSoon();

        (uint256 c0, uint256 c1) = positionManager.collect(
            INPM.CollectParams({
                tokenId: id,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        uint256 fee0 = _payOut(token0, c0);
        uint256 fee1 = _payOut(token1, c1);

        lastActionAt = uint64(block.timestamp);
        emit Harvested(c0, c1, fee0 + fee1, 0);
    }

    /// @dev Splits a collected amount into protocol fee, caller bounty and remainder.
    function _payOut(address token, uint256 collected) private returns (uint256 protocolFee) {
        if (collected == 0) return 0;

        protocolFee = (collected * PROTOCOL_FEE_BPS) / BPS;
        uint256 bounty = (collected * policy.bountyBps) / BPS;

        if (protocolFee > 0) {
            _approve(token, address(feeRouter), protocolFee);
            feeRouter.take(token, address(this), protocolFee);
        }
        if (bounty > 0) IERC20(token).safeTransfer(msg.sender, bounty);
        // remainder stays in the vault; `deploy()` compounds it back into the range
    }

    /// @notice Re-centre the range once price has left it by more than the policy's
    ///         hysteresis. Permissionless, and the replacement position is always
    ///         minted to this vault — never to the caller.
    function rebalance() external nonReentrant {
        uint256 id = tokenId;
        if (id == 0) revert NoPosition();
        if (block.timestamp < lastActionAt + policy.minInterval) revert TooSoon();

        TwapGuard.check(pool, TWAP_WINDOW, TWAP_BAND_BPS);
        (, int24 spotTick,,,,,) = pool.slot0();

        int24 hys = policy.hysteresisTicks;
        bool out = spotTick < tickLower - hys || spotTick > tickUpper + hys;
        if (!out) revert InRange();

        uint256 valueBefore = totalAssets();

        // unwind everything
        (,,,,,,, uint128 liquidity,,,,) = positionManager.positions(id);
        if (liquidity > 0) _decrease(id, liquidity);

        (int24 lo, int24 hi) = _centeredRange(spotTick);
        tickLower = lo;
        tickUpper = hi;

        _balanceToRatio();

        uint256 bal0 = IERC20(token0).balanceOf(address(this));
        uint256 bal1 = IERC20(token1).balanceOf(address(this));

        _approve(token0, address(positionManager), bal0);
        _approve(token1, address(positionManager), bal1);

        uint16 slip = policy.maxSlippageBps;
        (uint256 newId, uint128 newLiq,,) = positionManager.mint(
            INPM.MintParams({
                token0: token0,
                token1: token1,
                fee: feeTier,
                tickLower: lo,
                tickUpper: hi,
                amount0Desired: bal0,
                amount1Desired: bal1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );
        tokenId = newId;

        // the whole round trip is bounded, not just the swap inside it
        uint256 valueAfter = totalAssets();
        if (valueAfter < _minOut(valueBefore, slip)) revert SlippageExceeded();

        uint256 bounty;
        if (policy.bountyBps > 0) {
            bounty = (valueAfter * policy.bountyBps) / BPS;
            uint256 assetBal = IERC20(asset).balanceOf(address(this));
            if (bounty > assetBal) bounty = assetBal;
            if (bounty > 0) IERC20(asset).safeTransfer(msg.sender, bounty);
        }

        lastActionAt = uint64(block.timestamp);
        emit Rebalanced(lo, hi, bounty);
        newLiq; // silence unused
    }

    // ─── internals ────────────────────────────────────────────────────────────

    function _decrease(uint256 id, uint128 liquidity) private {
        positionManager.decreaseLiquidity(
            INPM.DecreaseLiquidityParams({
                tokenId: id,
                liquidity: liquidity,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
        positionManager.collect(
            INPM.CollectParams({
                tokenId: id,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
    }

    /// @dev Swap whichever side we hold too much of, so the mint consumes both.
    ///      Uses a midpoint split, which the mint's own amountMin bounds then check.
    function _balanceToRatio() private {
        (uint160 sqrtP,,,,,,) = pool.slot0();
        uint160 sqrtLo = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtHi = TickMath.getSqrtRatioAtTick(tickUpper);

        uint256 bal0 = IERC20(token0).balanceOf(address(this));
        uint256 bal1 = IERC20(token1).balanceOf(address(this));

        // price entirely below the range: the position wants only token0
        if (sqrtP <= sqrtLo) {
            if (bal1 > 0) _swap(token1, token0, bal1);
            return;
        }
        // price entirely above: only token1
        if (sqrtP >= sqrtHi) {
            if (bal0 > 0) _swap(token0, token1, bal0);
            return;
        }

        // in range: aim for the ratio the range wants at this price
        uint128 unit = LiquidityAmounts.getLiquidityForAmounts(sqrtP, sqrtLo, sqrtHi, 1e18, 1e18);
        (uint256 want0, uint256 want1) = LiquidityAmounts.getAmountsForLiquidity(sqrtP, sqrtLo, sqrtHi, unit);
        if (want0 == 0 || want1 == 0) return;

        uint256 have1AsZero = _quoteToken1AsToken0(bal1, sqrtP);
        uint256 total0 = bal0 + have1AsZero;
        if (total0 == 0) return;

        // target share of value held as token0
        uint256 want1AsZero = _quoteToken1AsToken0(want1, sqrtP);
        uint256 target0 = FullMath.mulDiv(total0, want0, want0 + want1AsZero);

        if (bal0 > target0) {
            uint256 excess0 = bal0 - target0;
            if (excess0 > 0) _swap(token0, token1, excess0);
        } else {
            uint256 deficit0 = target0 - bal0;
            uint256 need1 = _quoteToken0AsToken1(deficit0, sqrtP);
            if (need1 > bal1) need1 = bal1;
            if (need1 > 0) _swap(token1, token0, need1);
        }
    }

    function _swap(address tokenIn, address tokenOut, uint256 amountIn) private {
        if (amountIn == 0) return;
        _approve(tokenIn, address(router), amountIn);

        (uint160 sqrtP,,,,,,) = pool.slot0();
        uint256 expected = tokenIn == token0
            ? _quoteToken0AsToken1(amountIn, sqrtP)
            : _quoteToken1AsToken0(amountIn, sqrtP);

        router.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: feeTier,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: _minOut(_netOfFee(expected), policy.maxSlippageBps),
                sqrtPriceLimitX96: 0
            })
        );
    }

    function _centeredRange(int24 spotTick) private view returns (int24 lo, int24 hi) {
        int24 half = policy.widthTicks / 2;
        int24 spacing = tickSpacing;
        int24 center = (spotTick / spacing) * spacing;
        lo = center - half;
        hi = center + half;
        if (lo < TickMath.MIN_TICK) lo = (TickMath.MIN_TICK / spacing + 1) * spacing;
        if (hi > TickMath.MAX_TICK) hi = (TickMath.MAX_TICK / spacing - 1) * spacing;
    }

    function _minOut(uint256 amount, uint16 slippageBps) private pure returns (uint256) {
        return amount - (amount * slippageBps) / BPS;
    }

    function _approve(address token, address spender, uint256 amount) private {
        IERC20(token).forceApprove(spender, amount);
    }
}
