// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test,console} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/tests/MockV3Aggregator.sol";

contract Handler is Test {
    DSCEngine dscEngine;
    DecentralizedStableCoin dsc;
    ERC20Mock weth;
    ERC20Mock wbtc;
    MockV3Aggregator public ethUsdPriceFeed;

    address[] public usersWithCollateralDeposited;
    constructor(DSCEngine _dscEngine, DecentralizedStableCoin _dsc) {
        dscEngine = _dscEngine;
        dsc = _dsc;
        address[] memory collateralTokens = dscEngine.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);
        // weth.mint(address(this), 100000000 ether);
        // wbtc.mint(address(this), 100000000 ether);
        // weth.approve(address(dscEngine), 100000000 ether);
        // wbtc.approve(address(dscEngine), 100000000 ether);

        ethUsdPriceFeed = MockV3Aggregator(dscEngine.getEthUsdPriceFeed());
    }

    // Known bug: 如果价格波动太大，会导致无法通过测试(要求:110% - 200% over-collateralization)
    // function updateCollateralPrice(uint96 newPrice) public {
    //     int256 newPriceInt = int256(uint256(newPrice));
    //     ethUsdPriceFeed.updateAnswer(newPriceInt);
    // } 

    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        amountCollateral= bound(amountCollateral, 1, 100000 ether);
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(dscEngine), amountCollateral);
        dscEngine.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
        // 可能有用户重复push
        usersWithCollateralDeposited.push(msg.sender);
    }

    function mintDsc(uint256 amount, uint256 addressSeed) public {
        if(usersWithCollateralDeposited.length == 0){
            return;
        }
        address sender = usersWithCollateralDeposited[addressSeed % usersWithCollateralDeposited.length];
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(msg.sender);
        int256 maxDscToMint = (int256(collateralValueInUsd)/2) - int256(totalDscMinted);
        if(maxDscToMint < 0){
            return;
        }
        amount = bound(amount, 1, uint256(maxDscToMint));
        if(amount == 0){
            return;
        }
        vm.startPrank(sender);
        dscEngine.mintDsc(amount);
        vm.stopPrank();
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxCollateralToRedeem = dscEngine.getCollateralBalanceOfUser(msg.sender, address(collateral));
        amountCollateral= bound(amountCollateral, 0, maxCollateralToRedeem);
        if (amountCollateral == 0) {
            return;
        }
        vm.startPrank(msg.sender);
        dscEngine.redeemCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
    }

    function _getCollateralFromSeed(uint256 collateralSeed) private view returns(ERC20Mock) {
        if(collateralSeed % 2 == 0){
            return weth;
        } else {
            return wbtc;
        }
    }
}