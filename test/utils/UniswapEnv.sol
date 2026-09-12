// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice A plain ERC20 with mintable supply and configurable decimals, for tests.
contract MockERC20 is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Deploys a real Uniswap v3 environment from the canonical published
///         artifacts, rather than recompiling the sources.
///
/// @dev    v3-periphery pins `solidity =0.8.15` and OpenZeppelin 5 needs >=0.8.20,
///         so the two cannot share a compiler in one project. Deploying from the
///         official bytecode sidesteps that and, more importantly, gives us the
///         canonical pool init-code hash — the same bytecode we will put on the
///         testnet, so the addresses the periphery computes actually resolve.
library UniswapEnv {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    struct Deployment {
        address factory;
        address weth9;
        address positionManager;
        address swapRouter;
    }

    function deploy() internal returns (Deployment memory d) {
        d.factory = _create(_creationCode(
            "node_modules/@uniswap/v3-core/artifacts/contracts/UniswapV3Factory.sol/UniswapV3Factory.json"
        ));

        d.weth9 = address(new MockERC20("Wrapped Ether", "WETH", 18));

        bytes memory npmCode = abi.encodePacked(
            _creationCode(
                "node_modules/@uniswap/v3-periphery/artifacts/contracts/NonfungiblePositionManager.sol/NonfungiblePositionManager.json"
            ),
            abi.encode(d.factory, d.weth9, address(0))
        );
        d.positionManager = _create(npmCode);

        bytes memory routerCode = abi.encodePacked(
            _creationCode(
                "node_modules/@uniswap/v3-periphery/artifacts/contracts/SwapRouter.sol/SwapRouter.json"
            ),
            abi.encode(d.factory, d.weth9)
        );
        d.swapRouter = _create(routerCode);
    }

    function _creationCode(string memory artifactPath) private view returns (bytes memory) {
        string memory json = vm.readFile(artifactPath);
        return vm.parseJsonBytes(json, ".bytecode");
    }

    function _create(bytes memory code) private returns (address addr) {
        assembly {
            addr := create(0, add(code, 0x20), mload(code))
        }
        require(addr != address(0), "UniswapEnv: deploy failed");
    }
}

interface IUniV3Factory {
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface IPoolInit {
    function initialize(uint160 sqrtPriceX96) external;
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external;
    function slot0()
        external
        view
        returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
}

interface INpmMint {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
}

interface IRouterSwap {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);
}
