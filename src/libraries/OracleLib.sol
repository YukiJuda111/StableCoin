// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title OracleLib
 * @author Yuk1
 * @notice 用于检查Chainlink Oracle是否正常工作
 * 如果priceFeed不再更新，冻结DscEngine
 */

library OracleLib {
    error OracleLib__StablePrice();
    uint256 private constant TIMEOUT = 1 hours;
    function stablePriceCheck(AggregatorV3Interface priceFeed) 
        public 
        view 
        returns (uint80, int256,uint256, uint256, uint80) 
    {
        (uint80 roundId, int256 price, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) = priceFeed.latestRoundData();
        uint256 secondsSinceLastUpdate = block.timestamp - updatedAt;
        if(secondsSinceLastUpdate > TIMEOUT){
            // 如果超过1小时没有更新，冻结DscEngine
            revert OracleLib__StablePrice();
        }
        return (roundId, price, startedAt, updatedAt, answeredInRound);
    }
}