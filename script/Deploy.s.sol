// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CaliperVault} from "../src/CaliperVault.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {Policy} from "../src/libraries/Policy.sol";

import {MockERC20, IUniV3Factory, IPoolInit, INpmMint} from "../test/utils/UniswapEnv.sol";

/// @notice Full stack deploy for Robinhood Chain testnet (chainId 46630).
///
/// @dev    The testnet has no Uniswap v3, so this puts the canonical bytecode down
///         first, then the Caliper contracts on top, then seeds one live pool and
///         one vault so the app has something real to read.
///
///         Run with:
///           forge script script/Deploy.s.sol:Deploy \
///             --rpc-url rhtestnet --broadcast --slow \
///             --private-key $DEPLOYER_KEY
contract Deploy is Script {
    // written to deployments/<chainid>.json at the end
    struct Out {
        address uniFactory;
        address positionManager;
        address swapRouter;
        address weth;
        address usdc;
        address pool;
        address feeRouter;
        address vaultImpl;
        address vaultFactory;
        address vault;
    }

    Out internal o;

    uint24 constant FEE = 3000;
    int24 constant SPACING = 60;
    // 1 tWETH = 2500 tUSDC, expressed as the raw token1/token0 ratio.
    // tWETH has 18 decimals and tUSDC has 6, so the raw price is
    // 2500 * 1e6 / 1e18 = 2.5e-9, and sqrt(2.5e-9) * 2^96 is the value below.
    // Initialising at a raw 1:1 instead would imply 1 WETH = 1e12 USDC and leave
    // the pool with no usable depth.
    uint160 constant SQRT_2500 = 3961408125713217069514752;
    int24 constant SPOT_TICK = -198079;   // ln(2.5e-9)/ln(1.0001)
    int24 constant SEED_LOWER = -238080;  // straddles spot, aligned to spacing 60
    int24 constant SEED_UPPER = -158100;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(pk);
        console2.log("deployer :", deployer);
        console2.log("balance  :", deployer.balance);
        require(deployer.balance > 0, "deployer has no gas - fund it first");

        vm.startBroadcast(pk);

        // ── 1. Uniswap v3, from canonical artifacts ──────────────────────────
        o.uniFactory = _create(_code(
            "node_modules/@uniswap/v3-core/artifacts/contracts/UniswapV3Factory.sol/UniswapV3Factory.json"
        ));
        console2.log("UniswapV3Factory  :", o.uniFactory);

        MockERC20 weth = new MockERC20("Caliper Test WETH", "tWETH", 18);
        MockERC20 usdc = new MockERC20("Caliper Test USDC", "tUSDC", 6);
        o.weth = address(weth);
        o.usdc = address(usdc);
        console2.log("tWETH             :", o.weth);
        console2.log("tUSDC             :", o.usdc);

        o.positionManager = _create(
            abi.encodePacked(
                _code(
                    "node_modules/@uniswap/v3-periphery/artifacts/contracts/NonfungiblePositionManager.sol/NonfungiblePositionManager.json"
                ),
                abi.encode(o.uniFactory, o.weth, address(0))
            )
        );
        console2.log("PositionManager   :", o.positionManager);

        o.swapRouter = _create(
            abi.encodePacked(
                _code("node_modules/@uniswap/v3-periphery/artifacts/contracts/SwapRouter.sol/SwapRouter.json"),
                abi.encode(o.uniFactory, o.weth)
            )
        );
        console2.log("SwapRouter        :", o.swapRouter);

        // ── 2. a live pool with real depth and oracle history ────────────────
        (address t0, address t1) = o.weth < o.usdc ? (o.weth, o.usdc) : (o.usdc, o.weth);
        o.pool = IUniV3Factory(o.uniFactory).createPool(t0, t1, FEE);
        IPoolInit(o.pool).initialize(SQRT_2500);
        IPoolInit(o.pool).increaseObservationCardinalityNext(120);
        console2.log("Pool              :", o.pool);

        weth.mint(deployer, 2_000_000e18);
        usdc.mint(deployer, 4_000_000_000e6);
        IERC20(t0).approve(o.positionManager, type(uint256).max);
        IERC20(t1).approve(o.positionManager, type(uint256).max);

        INpmMint(o.positionManager).mint(
            INpmMint.MintParams({
                token0: t0,
                token1: t1,
                fee: FEE,
                tickLower: SEED_LOWER,
                tickUpper: SEED_UPPER,
                amount0Desired: t0 == o.weth ? 400e18 : 1_000_000e6,
                amount1Desired: t1 == o.weth ? 400e18 : 1_000_000e6,
                amount0Min: 0,
                amount1Min: 0,
                recipient: deployer,
                deadline: block.timestamp + 1200
            })
        );
        console2.log("seeded pool liquidity");

        // ── 3. Caliper ───────────────────────────────────────────────────────
        o.feeRouter = address(new FeeRouter(deployer)); // treasury = deployer on testnet
        o.vaultImpl = address(new CaliperVault());
        o.vaultFactory =
            address(new VaultFactory(o.vaultImpl, o.feeRouter, o.positionManager, o.swapRouter));
        console2.log("FeeRouter         :", o.feeRouter);
        console2.log("VaultImpl         :", o.vaultImpl);
        console2.log("VaultFactory      :", o.vaultFactory);

        Policy memory policy = Policy({
            widthTicks: 1200,        // +/- 3% band, on 60 spacing
            hysteresisTicks: 120,
            minInterval: 3600,
            maxSlippageBps: 300,
            compound: true,
            bountyBps: 100
        });

        o.vault = VaultFactory(o.vaultFactory).createVault(
            o.pool, o.weth, 1_000_000e18, policy, "Caliper tWETH Vault", "cWETH"
        );
        console2.log("Vault             :", o.vault);

        vm.stopBroadcast();

        _write();
    }

    function _code(string memory path) internal view returns (bytes memory) {
        return vm.parseJsonBytes(vm.readFile(path), ".bytecode");
    }

    function _create(bytes memory code) internal returns (address addr) {
        assembly {
            addr := create(0, add(code, 0x20), mload(code))
        }
        require(addr != address(0), "deploy failed");
    }

    function _write() internal {
        string memory j = "d";
        vm.serializeAddress(j, "uniFactory", o.uniFactory);
        vm.serializeAddress(j, "positionManager", o.positionManager);
        vm.serializeAddress(j, "swapRouter", o.swapRouter);
        vm.serializeAddress(j, "weth", o.weth);
        vm.serializeAddress(j, "usdc", o.usdc);
        vm.serializeAddress(j, "pool", o.pool);
        vm.serializeAddress(j, "feeRouter", o.feeRouter);
        vm.serializeAddress(j, "vaultImpl", o.vaultImpl);
        vm.serializeAddress(j, "vaultFactory", o.vaultFactory);
        string memory out = vm.serializeAddress(j, "vault", o.vault);

        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(out, path);
        console2.log("wrote", path);
    }
}
