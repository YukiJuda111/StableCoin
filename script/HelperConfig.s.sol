// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Script} from "forge-std/Script.sol";

contract HelperConfig is Script {
    struct NetworkConfig {
        address wethUsdPriceFeed;
        address wbtcUsdPriceFeed;
        address weth;
        address wbtc;
        uint256 deployerKey;
    }

    NetworkConfig public activeNetworkConfig;

    constructor() {}

    function getSepoliaEthConfig() public view returns(NetworkConfig memory) {
        return NetworkConfig(
            0x8A753747A1Fa494EC906cE90E9f37563A8AF630e,
            0x6135b13325bfC4B00278B4abC5e20bbce2D6580e,
            0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,
            0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599,
            0x0
        );
    }
}