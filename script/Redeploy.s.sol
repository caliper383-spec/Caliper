// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {CaliperVault} from "../src/CaliperVault.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {Policy} from "../src/libraries/Policy.sol";

/// @notice Redeploys only the Caliper layer, reusing the Uniswap deployment, the
///         tokens and the already-warm pool from a previous run.
contract Redeploy is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(pk);

        string memory j = vm.readFile("deployments/46630.json");
        address pool = vm.parseJsonAddress(j, ".pool");
        address npm = vm.parseJsonAddress(j, ".positionManager");
        address swapRouter = vm.parseJsonAddress(j, ".swapRouter");
        address weth = vm.parseJsonAddress(j, ".weth");

        vm.startBroadcast(pk);

        address feeRouter = address(new FeeRouter(deployer));
        address impl = address(new CaliperVault());
        VaultFactory f = new VaultFactory(impl, feeRouter, npm, swapRouter);

        Policy memory policy = Policy({
            widthTicks: 1200,
            hysteresisTicks: 120,
            minInterval: 3600,
            maxSlippageBps: 300,
            compound: true,
            bountyBps: 100
        });

        address vault = f.createVault(pool, weth, 1_000_000e18, policy, "Caliper tWETH Vault", "cWETH");

        vm.stopBroadcast();

        console2.log("FeeRouter    :", feeRouter);
        console2.log("VaultImpl    :", impl);
        console2.log("VaultFactory :", address(f));
        console2.log("Vault        :", vault);

        string memory k = "d";
        vm.serializeAddress(k, "uniFactory", vm.parseJsonAddress(j, ".uniFactory"));
        vm.serializeAddress(k, "positionManager", npm);
        vm.serializeAddress(k, "swapRouter", swapRouter);
        vm.serializeAddress(k, "weth", weth);
        vm.serializeAddress(k, "usdc", vm.parseJsonAddress(j, ".usdc"));
        vm.serializeAddress(k, "pool", pool);
        vm.serializeAddress(k, "feeRouter", feeRouter);
        vm.serializeAddress(k, "vaultImpl", impl);
        vm.serializeAddress(k, "vaultFactory", address(f));
        string memory out = vm.serializeAddress(k, "vault", vault);
        vm.writeJson(out, "deployments/46630.json");
    }
}
