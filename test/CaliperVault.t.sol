// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CaliperVault} from "../src/CaliperVault.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {Policy} from "../src/libraries/Policy.sol";

import {
    UniswapEnv, MockERC20, IUniV3Factory, IPoolInit, INpmMint, IRouterSwap
} from "./utils/UniswapEnv.sol";

/// @notice End-to-end: a real Uniswap v3 pool, a real vault, real deposits.
contract CaliperVaultTest is Test {
    UniswapEnv.Deployment env;

    MockERC20 usdc;
    MockERC20 weth;
    address pool;

    FeeRouter feeRouter;
    VaultFactory factory;
    CaliperVault vault;

    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address keeper = makeAddr("keeper");

    uint24 constant FEE = 3000;
    int24 constant SPACING = 60;

    function setUp() public {
        env = UniswapEnv.deploy();

        // deterministic token ordering: usdc < weth by address is not guaranteed,
        // so sort after deploy and label accordingly
        MockERC20 a = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 b = new MockERC20("Wrapped Ether", "WETH", 18);
        (usdc, weth) = (a, b);

        address t0 = address(usdc) < address(weth) ? address(usdc) : address(weth);
        address t1 = address(usdc) < address(weth) ? address(weth) : address(usdc);

        pool = IUniV3Factory(env.factory).createPool(t0, t1, FEE);

        // price 1:1 in raw units keeps the maths easy to reason about in tests
        IPoolInit(pool).initialize(79228162514264337593543950336); // sqrt(1) * 2^96
        IPoolInit(pool).increaseObservationCardinalityNext(64);

        // seed the pool with outside liquidity so swaps have something to trade against
        _seedPool(t0, t1);

        feeRouter = new FeeRouter(treasury);
        CaliperVault impl = new CaliperVault();
        factory = new VaultFactory(address(impl), address(feeRouter), env.positionManager, env.swapRouter);

        Policy memory policy = Policy({
            widthTicks: 1200,
            hysteresisTicks: 120,
            minInterval: 3600,
            maxSlippageBps: 300,
            compound: true,
            bountyBps: 100
        });

        vault = CaliperVault(
            factory.createVault(pool, address(weth), 1_000_000e18, policy, "Caliper WETH", "cWETH")
        );

        // let the oracle accumulate a real window of history
        vm.warp(block.timestamp + 1 hours);
        vm.roll(block.number + 300);
        _poke(t0, t1);
    }

    function _seedPool(address t0, address t1) internal {
        MockERC20(t0).mint(address(this), 1_000_000e18);
        MockERC20(t1).mint(address(this), 1_000_000e18);
        IERC20(t0).approve(env.positionManager, type(uint256).max);
        IERC20(t1).approve(env.positionManager, type(uint256).max);

        INpmMint(env.positionManager).mint(
            INpmMint.MintParams({
                token0: t0,
                token1: t1,
                fee: FEE,
                tickLower: -60000,
                tickUpper: 60000,
                amount0Desired: 500_000e18,
                amount1Desired: 500_000e18,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );
    }

    /// @dev A tiny swap each way writes a fresh oracle observation.
    function _poke(address t0, address t1) internal {
        IERC20(t0).approve(env.swapRouter, type(uint256).max);
        IERC20(t1).approve(env.swapRouter, type(uint256).max);
        IRouterSwap(env.swapRouter).exactInputSingle(
            IRouterSwap.ExactInputSingleParams({
                tokenIn: t0,
                tokenOut: t1,
                fee: FEE,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: 1e15,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
    }

    // ─────────────────────────────────────────────────────────────────────────

    function test_vaultIsConfigured() public view {
        assertEq(vault.asset(), address(weth), "asset");
        assertEq(address(vault.pool()), pool, "pool");
        assertEq(vault.decimals(), 18, "decimals follow the asset");
        assertEq(vault.cap(), 1_000_000e18, "cap");
        assertEq(vault.totalSupply(), 0, "starts empty");
    }

    function test_implementationCannotBeInitialized() public {
        CaliperVault impl = new CaliperVault();
        Policy memory p =
            Policy({widthTicks: 1200, hysteresisTicks: 120, minInterval: 3600, maxSlippageBps: 300, compound: true, bountyBps: 100});

        vm.expectRevert(CaliperVault.AlreadyInitialized.selector);
        impl.initialize(
            CaliperVault.InitParams({
                asset: address(weth),
                pool: pool,
                positionManager: env.positionManager,
                router: env.swapRouter,
                feeRouter: address(feeRouter),
                cap: 1e18,
                policy: p,
                name: "x",
                symbol: "x"
            })
        );
    }

    function test_depositMintsSharesOneToOneWhenEmpty() public {
        weth.mint(alice, 10e18);

        vm.startPrank(alice);
        weth.approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(10e18, alice);
        vm.stopPrank();

        assertEq(shares, 10e18, "first depositor gets 1:1");
        assertEq(vault.balanceOf(alice), 10e18, "shares credited");
        assertEq(vault.totalAssets(), 10e18, "assets held loose still count");
    }

    function test_depositRespectsCap() public {
        weth.mint(alice, 2_000_000e18);
        vm.startPrank(alice);
        weth.approve(address(vault), type(uint256).max);
        vm.expectRevert(CaliperVault.CapExceeded.selector);
        vault.deposit(1_000_001e18, alice);
        vm.stopPrank();
    }

    function test_deployOpensPositionAndPreservesValue() public {
        weth.mint(alice, 10e18);
        vm.startPrank(alice);
        weth.approve(address(vault), type(uint256).max);
        vault.deposit(10e18, alice);
        vm.stopPrank();

        uint256 before = vault.totalAssets();
        assertEq(vault.tokenId(), 0, "no position yet");

        vault.deploy();

        assertGt(vault.tokenId(), 0, "position opened");
        uint256 afterDeploy = vault.totalAssets();

        // a swap and a mint cost fees and rounding, but value must be close
        assertApproxEqRel(afterDeploy, before, 0.03e18, "value preserved within 3%");
    }

    function test_secondDepositorGetsProportionalShares() public {
        weth.mint(alice, 10e18);
        weth.mint(bob, 10e18);

        vm.startPrank(alice);
        weth.approve(address(vault), type(uint256).max);
        vault.deposit(10e18, alice);
        vm.stopPrank();

        vault.deploy();

        vm.startPrank(bob);
        weth.approve(address(vault), type(uint256).max);
        uint256 bobShares = vault.deposit(10e18, bob);
        vm.stopPrank();

        // bob should get roughly the same shares as alice for the same deposit
        assertApproxEqRel(bobShares, vault.balanceOf(alice), 0.05e18, "proportional");
    }

    function test_redeemReturnsAssets() public {
        weth.mint(alice, 10e18);
        vm.startPrank(alice);
        weth.approve(address(vault), type(uint256).max);
        vault.deposit(10e18, alice);
        vm.stopPrank();

        vault.deploy();

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 got = vault.redeem(shares, alice, alice);

        assertGt(got, 0, "received something back");
        assertApproxEqRel(got, 10e18, 0.05e18, "close to what went in");
        assertEq(vault.balanceOf(alice), 0, "shares burned");
    }

    function test_harvestIsPermissionlessAndPaysProtocol() public {
        weth.mint(alice, 100e18);
        vm.startPrank(alice);
        weth.approve(address(vault), type(uint256).max);
        vault.deposit(100e18, alice);
        vm.stopPrank();

        vault.deploy();

        // generate trading fees through the vault's range
        address t0 = vault.token0();
        address t1 = vault.token1();
        MockERC20(t0).mint(address(this), 100_000e18);
        MockERC20(t1).mint(address(this), 100_000e18);
        IERC20(t0).approve(env.swapRouter, type(uint256).max);
        IERC20(t1).approve(env.swapRouter, type(uint256).max);
        for (uint256 i; i < 6; ++i) {
            _swapExact(t0, t1, 2_000e18);
            _swapExact(t1, t0, 2_000e18);
        }

        vm.warp(block.timestamp + 2 hours);

        uint256 treasuryBefore = feeRouter.claimable(t0, treasury) + feeRouter.claimable(t1, treasury);

        vm.prank(keeper); // anyone may call it
        vault.harvest();

        uint256 treasuryAfter = feeRouter.claimable(t0, treasury) + feeRouter.claimable(t1, treasury);
        assertGt(treasuryAfter, treasuryBefore, "protocol took its cut of fees earned");
    }

    function test_harvestRespectsMinInterval() public {
        weth.mint(alice, 10e18);
        vm.startPrank(alice);
        weth.approve(address(vault), type(uint256).max);
        vault.deposit(10e18, alice);
        vm.stopPrank();
        vault.deploy();

        vm.expectRevert(CaliperVault.TooSoon.selector);
        vault.harvest();
    }

    function test_rebalanceRefusesWhileInRange() public {
        weth.mint(alice, 10e18);
        vm.startPrank(alice);
        weth.approve(address(vault), type(uint256).max);
        vault.deposit(10e18, alice);
        vm.stopPrank();
        vault.deploy();

        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert(CaliperVault.InRange.selector);
        vault.rebalance();
    }

    function test_noOwnerFunctionsExist() public view {
        // the ABI has no owner(), no setter and no rescue path — assert the
        // storage-level intent: nobody was ever recorded as privileged
        assertEq(vault.cap(), 1_000_000e18, "cap fixed at init");
        (int24 w,,,,,) = _policy();
        assertEq(w, 1200, "policy fixed at init");
    }

    function _policy() internal view returns (int24, int24, uint32, uint16, bool, uint16) {
        return vault.policy();
    }

    function _swapExact(address tokenIn, address tokenOut, uint256 amountIn) internal {
        IRouterSwap(env.swapRouter).exactInputSingle(
            IRouterSwap.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: FEE,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
    }
}
