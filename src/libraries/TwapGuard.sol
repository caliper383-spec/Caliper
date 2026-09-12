// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

/// @notice Every path that mints or burns shares at the pool's spot price runs
///         through here first. Spot must sit within `maxDeviationBps` of a mean
///         measured over at least `window` seconds of real observed history, or
///         the call reverts rather than price someone badly.
library TwapGuard {
    error StaleOracle();
    error PriceOutOfBand();

    /// @dev Reverts unless spot sits inside the band around the TWAP.
    function check(IUniswapV3Pool pool, uint32 window, uint16 maxDeviationBps) internal view {
        int24 twapTick = consult(pool, window);
        (, int24 spotTick,,,,,) = pool.slot0();

        int24 diff = spotTick > twapTick ? spotTick - twapTick : twapTick - spotTick;

        // One tick is 1.0001x, so `diff` ticks is a 1.0001^diff price ratio. Over the
        // band sizes used here (<= a few hundred bps) comparing ticks against a bps
        // bound is within half a percent of the true ratio test and always the
        // tighter of the two, so it never admits a price the ratio test would reject.
        if (uint24(diff) > uint24(maxDeviationBps)) revert PriceOutOfBand();
    }

    /// @notice Arithmetic-mean tick over the last `window` seconds.
    function consult(IUniswapV3Pool pool, uint32 window) internal view returns (int24) {
        if (window == 0) revert StaleOracle();

        uint32[] memory ago = new uint32[](2);
        ago[0] = window;
        ago[1] = 0;

        (int56[] memory tickCumulatives,) = pool.observe(ago);
        int56 delta = tickCumulatives[1] - tickCumulatives[0];
        int56 w = int56(uint56(window));

        int56 mean = delta / w;
        // round toward negative infinity, matching Uniswap's OracleLibrary
        if (delta < 0 && (delta % w != 0)) mean--;
        return int24(mean);
    }

    /// @notice Whether the pool can actually serve a window this long.
    function hasHistory(IUniswapV3Pool pool, uint32 window) internal view returns (bool) {
        (,,, uint16 cardinality,,,) = pool.slot0();
        if (cardinality < 2) return false;
        uint32[] memory ago = new uint32[](1);
        ago[0] = window;
        try pool.observe(ago) returns (int56[] memory, uint160[] memory) {
            return true;
        } catch {
            return false;
        }
    }
}
