// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {CaliperVault} from "./CaliperVault.sol";
import {Policy} from "./libraries/Policy.sol";

/// @notice Deploys vaults as EIP-1167 clones of one implementation.
/// @dev    No owner and no allow-list: creating a vault is permissionless, and the
///         implementation address is immutable so a clone can never be re-pointed.
///         Clone and initialise happen in the same call, so there is never a block
///         in which an unconfigured clone exists for someone else to claim.
contract VaultFactory {
    address public immutable implementation;
    address public immutable feeRouter;
    address public immutable positionManager;
    address public immutable router;

    address[] public allVaults;
    mapping(address pool => mapping(address asset => address vault)) public vaultFor;

    event VaultCreated(
        address indexed vault, address indexed pool, address indexed asset, uint256 cap, string symbol
    );

    error ZeroAddress();
    error VaultExists();

    constructor(address _implementation, address _feeRouter, address _positionManager, address _router) {
        if (
            _implementation == address(0) || _feeRouter == address(0) || _positionManager == address(0)
                || _router == address(0)
        ) revert ZeroAddress();
        implementation = _implementation;
        feeRouter = _feeRouter;
        positionManager = _positionManager;
        router = _router;
    }

    function createVault(
        address pool,
        address asset,
        uint256 cap,
        Policy calldata policy,
        string calldata name,
        string calldata symbol
    ) external returns (address vault) {
        if (vaultFor[pool][asset] != address(0)) revert VaultExists();

        vault = Clones.clone(implementation);

        CaliperVault(vault).initialize(
            CaliperVault.InitParams({
                asset: asset,
                pool: pool,
                positionManager: positionManager,
                router: router,
                feeRouter: feeRouter,
                cap: cap,
                policy: policy,
                name: name,
                symbol: symbol
            })
        );

        vaultFor[pool][asset] = vault;
        allVaults.push(vault);
        emit VaultCreated(vault, pool, asset, cap, symbol);
    }

    function vaultCount() external view returns (uint256) {
        return allVaults.length;
    }
}
