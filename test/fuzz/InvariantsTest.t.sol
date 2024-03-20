// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

// total supply of Dsc should be less than the tatal value of the collateral
import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Handler} from "./Handler.t.sol";

contract InvariantsTest is StdInvariant,Test {
    DeployDSC deployer;
    DSCEngine dscEngine;
    DecentralizedStableCoin dsc;
    HelperConfig config;
    address weth;
    address wbtc;
    Handler handler;
    function setUp() external {
        deployer = new DeployDSC();
        (dsc, dscEngine, config) = deployer.run();
        ( , , weth, wbtc, ) = config.activeNetworkConfig();
        handler = new Handler(dscEngine, dsc);
        targetContract(address(handler));
    }

    function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dscEngine));
        uint256 totlWbtcDeposited = IERC20(wbtc).balanceOf(address(dscEngine)); // fix bug
        // console.log("Deposited weth: ", totalWethDeposited);
        // console.log("Deposited wbtc: ", totlWbtcDeposited);
        uint256 wethValue = dscEngine.getUsdValue(weth, totalWethDeposited);
        uint256 wbtcValue = dscEngine.getUsdValue(wbtc, totlWbtcDeposited);

        console.log("Total Supply: ", totalSupply);
        console.log("Total Weth Deposited: ", totalWethDeposited);
        console.log("Total Wbtc Deposited: ", totlWbtcDeposited);
        assert (wethValue + wbtcValue >= totalSupply);
    }
}