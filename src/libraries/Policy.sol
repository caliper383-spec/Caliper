// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @notice Rules a position is managed under. Set by the position's owner and
///         read identically by the vault, the keeper and the off-chain bot.
struct Policy {
    int24  widthTicks;      // total width of the range a re-centre mints
    int24  hysteresisTicks; // how far past the edge before a re-centre is allowed
    uint32 minInterval;     // seconds between actions
    uint16 maxSlippageBps;  // bound on the swap, the mint ratio and the round trip
    bool   compound;        // harvest puts the remainder back in, or pays it out
    uint16 bountyBps;       // paid to whoever spends the gas, capped by the contract
}

library PolicyLib {
    uint16 internal constant MAX_BOUNTY_BPS = 300;
    uint16 internal constant BPS = 10_000;

    error BadPolicy();

    function validate(Policy memory p, int24 spacing) internal pure {
        if (p.widthTicks <= 0) revert BadPolicy();
        if (p.widthTicks % spacing != 0) revert BadPolicy();
        if (p.hysteresisTicks < 0) revert BadPolicy();
        if (p.maxSlippageBps >= BPS) revert BadPolicy();
        if (p.bountyBps > MAX_BOUNTY_BPS) revert BadPolicy();
    }
}
