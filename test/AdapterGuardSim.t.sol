// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../contracts/adapters/BaseCBBTCYieldAdapter.sol";

/// Validates the hardening on a Base fork using the LIVE adapter's own
/// immutables, so no addresses are hand-typed beyond the known wrong aToken.
///
/// Run: forge test --match-contract AdapterGuardSim -vvv --fork-url $BASE_RPC_URL
interface ILive {
    function controller() external view returns (address);
    function cbbtc() external view returns (address);
    function aavePool() external view returns (address);
    function aerodromeStrategy() external view returns (address);
    function priceFeed() external view returns (address);
    function rescueReceiver() external view returns (address);
}

import "../contracts/interfaces/IAaveV3.sol";

interface IERC20bal { function balanceOf(address) external view returns (uint256); }

contract AdapterGuardSim is Test {
    address constant LIVE         = 0x327A430131940DBDdA3A79319c7e30BbdDe1EF15;
    address constant WRONG_ATOKEN = 0x0a1d576f3eFeF75b330424287a95A366e8281D54; // aBasUSDbC (the bug)
    address constant OWNER        = 0x13c142E565d28b1558BecAA2Af4495CB133801f4;

    function _params()
        internal view
        returns (address cbbtc, address pool, address aero, address feed, address ctrl, address rescue, address realAToken)
    {
        ILive live = ILive(LIVE);
        cbbtc = live.cbbtc();
        pool = live.aavePool();
        aero = live.aerodromeStrategy();
        feed = live.priceFeed();
        ctrl = live.controller();
        rescue = live.rescueReceiver();
        realAToken = IAaveReserveQuery(pool).getReserveData(cbbtc).aTokenAddress;
    }

    function testConstructorAcceptsCorrectAToken() public {
        (address cbbtc, address pool, address aero, address feed, address ctrl, address rescue, address realAToken) = _params();
        BaseCBBTCYieldAdapter ok =
            new BaseCBBTCYieldAdapter(OWNER, ctrl, cbbtc, pool, realAToken, aero, feed, rescue, 0);
        assertEq(address(ok.aCbbtc()), realAToken, "correct aToken should deploy");
    }

    function testConstructorRejectsWrongAToken() public {
        (address cbbtc, address pool, address aero, address feed, address ctrl, address rescue,) = _params();
        // The exact mis-config that stranded funds must now revert at deploy.
        vm.expectRevert();
        new BaseCBBTCYieldAdapter(OWNER, ctrl, cbbtc, pool, WRONG_ATOKEN, aero, feed, rescue, 0);
    }

    function testRescueTokenMovesStuckToken() public {
        (address cbbtc, address pool, address aero, address feed, address ctrl, address rescue, address realAToken) = _params();
        BaseCBBTCYieldAdapter a =
            new BaseCBBTCYieldAdapter(OWNER, ctrl, cbbtc, pool, realAToken, aero, feed, rescue, 0);

        deal(cbbtc, address(a), 1e8);
        vm.prank(OWNER);
        a.rescueToken(cbbtc, 1e8, address(0xBEEF));
        assertEq(IERC20bal(cbbtc).balanceOf(address(0xBEEF)), 1e8, "rescue should move the token");
    }
}
