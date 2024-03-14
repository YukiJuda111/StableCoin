// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSCEngine
 * @author Yuk1
 * @notice Usage : maintain 1 USD = 1 TOKEN
 * @notice Similar to the DAI engine
 * @notice Our Dsc system should always be "over-collateralized" to ensure
 *  that the value of the collateral is always greater than the value of the Dsc
 */
contract DSCEngine is ReentrancyGuard {
    ////////////////////
    /// Errors   ///////
    ////////////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressAndPriceFeedAddressMustBeEqualLength();
    error DSCEngine__TokenIsNotAllowed();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 userHealthFactor);
    error DSCEngine__MintFailed();


    //////////////////////
    /// State Variables //
    //////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISON = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; 
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256) private s_dscMinted;

    address[] private s_collateralTokens;
    DecentralizedStableCoin private immutable i_dsc;

    ////////////////////
    /// Events   ///////
    ////////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);

    ////////////////////
    /// Modifiers   ////
    ////////////////////
    modifier moreThanZero(uint256 _amount) {
        if (_amount <= 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address _token) {
        if (s_priceFeeds[_token] == address(0)) {
            revert DSCEngine__TokenIsNotAllowed();
        }
        _;
    }

    ////////////////////
    /// Fuctions   /////
    ////////////////////
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressAndPriceFeedAddressMustBeEqualLength();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    function depositCollateralAndMintDsc() external {}

    /**
     * @param tokenCollateral 作为抵押物的token的地址
     * @param amoutCollateral 抵押物的数量
     */
    function depositCollateral(address tokenCollateral, uint256 amoutCollateral)
        external
        moreThanZero(amoutCollateral)
        isAllowedToken(tokenCollateral)
        nonReentrant // 不可重入(more gas fee, safer)
    {
        s_collateralDeposited[msg.sender][tokenCollateral] += amoutCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateral, amoutCollateral);
        bool success = IERC20(tokenCollateral).transferFrom(msg.sender, address(this), amoutCollateral);
        if(!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function redeemCollateralForDsc() external {}

    function redeemCollateral() external {}

    /**
     * @param amountDscToMint 铸造的DSC数量
     * @notice collateralization value > minted DSC value
     */
    function mintDsc(uint256 amountDscToMint)
        external 
        moreThanZero(amountDscToMint)
        nonReentrant
    {
        s_dscMinted[msg.sender] += amountDscToMint;
        // if minted too much, revert(e.g. $150 DSC, $100 collateral)
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if(!minted){
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc() external {}

    function liquidate() external {}

    function getHealthFactor() external view {}


    //////////////////////////// 
    /// Private and Internal ///
    ////////////////////////////

    /**
     * @param user address of the user
     */
    function _getAccountInformation(address user) private view returns (uint256, uint256) {
        uint256 totalDscMinted = s_dscMinted[user];
        uint256 collateralValueInUsd = getAccountCollateralValue(user);
        return (totalDscMinted, collateralValueInUsd);
    }

    /**
     * @param user user address
     * @notice returns how close to liquidation the user is
     * @notice If a user goes below 1, the user is liquidated
     */
    function _healthFactor(address user) private view returns (uint256) {
        // total DSC minted
        // total collateral deposited
        (uint256 totalDscMinted, uint256 totalCollateralInUsd) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold = totalCollateralInUsd * LIQUIDATION_THRESHOLD / LIQUIDATION_PRECISION;
        // 200% over-collateralized
        return (collateralAdjustedForThreshold * PRECISON) / totalDscMinted;
    }


    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    ///////////////////////////////////////
    /// Pubic & External View Functions ///
    ///////////////////////////////////////
    function getAccountCollateralValue(address user) public view returns (uint256) {
        uint256 totalCollateralInUsd = 0;
        for(uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralInUsd += getUsdValue(token, amount);
        }
        return totalCollateralInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns(uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        ( , int price, , , ) = priceFeed.latestRoundData();
        // 从chainlink返回的价格是8位小数
        return uint256(price) * ADDITIONAL_FEED_PRECISION * amount / PRECISON;
    }
}
