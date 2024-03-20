// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {console} from "forge-std/console.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/**
 * @title DSCEngine
 * @author Yuk1
 * @notice Usage : maintain 1 USD = 1 TOKEN
 * @notice Similar to the DAI engine
 * @notice Our Dsc system should always be "over-collateralized" to ensure
 *  that the value of the collateral is always greater than the value of the Dsc
 * @notice 这个系统只有在 110% - 200% over-collateralized的情况下才能正常运行
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
    error DSCEngine__HealthFactorFine();
    error DSCEngine__HealthFactorNotImproved();

    using OracleLib for AggregatorV3Interface;

    //////////////////////
    /// State Variables //
    //////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISON = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; 
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; 

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256) private s_dscMinted;

    address[] private s_collateralTokens;
    DecentralizedStableCoin private immutable i_dsc;

    ////////////////////
    /// Events   ///////
    ////////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed redeemedFrom, address indexed redeemedTo, uint256 indexed amount, address token);

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

    /**
     * 
     * @param tokenCollateralAddress 要存的token的地址
     * @param amountCollateral 要存的token数量
     * @param amountDscToMint 铸造DSC的数量
     */
    function depositCollateralAndMintDsc
    (
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     * @param tokenCollateral 作为抵押物的token的地址
     * @param amoutCollateral 抵押物的数量
     */
    function depositCollateral(address tokenCollateral, uint256 amoutCollateral)
        public
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
        _revertIfHealthFactorIsBroken(msg.sender);
        console.log("now balance: ", IERC20(tokenCollateral).balanceOf(address(this)));
    }

    /**
     * 
     * @param tokenCollateralAddress 质押物的地址
     * @param amountCollateral 质押物的数量
     * @param amountDscToBurn 销毁的DSC数量
     */
    function redeemCollateralForDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral, uint256 amountDscToBurn
    ) external {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    //取回质押物，需要health factor > 1
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public 
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @param amountDscToMint 铸造的DSC数量
     * @notice collateralization value > minted DSC value
     */
    function mintDsc(uint256 amountDscToMint)
        public 
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

    function burnDsc(uint256 amountDscToBurn)
        public 
        moreThanZero(amountDscToBurn)
    {
        _burnDsc(amountDscToBurn, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // I dont think this is necessary
    }

    // 检测某人是否under-collateralized，如果是，就以打折的形式liquidate
    /**
     * 
     * @param collateral erc20 token address
     * @param user under-collateralized user(health factor < 1)
     * @param debtToCover The amount of DSC you want to burn to improve the user's health factor
     * @notice 必备条件: over-collateralized(合约中存储的质押物的价值 > minted DSC的价值)
     */
    function liquidate(address collateral, address user, uint256 debtToCover) 
        external 
        moreThanZero(debtToCover)
        isAllowedToken(collateral)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if(startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorFine();
        }

        // 拿走质押物
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        // 给liquidator 10% bonus
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(collateral, totalCollateralToRedeem, user, msg.sender);

        // 销毁DSC,msg.sender支付,user的DSC被销毁
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if(endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }


    //////////////////////////// 
    /// Private and Internal ///
    ////////////////////////////
    function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral,
    address from, address to) private {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, amountCollateral, tokenCollateralAddress);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if(!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_dscMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if(!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn); // only owner can burn
    }

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
        if (totalDscMinted == 0) return type(uint256).max; // wtf
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
    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns(uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        ( , int price, , , ) = priceFeed.latestRoundData();
        // 从chainlink返回的价格是8位小数
        return usdAmountInWei * PRECISON / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

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
        ( , int price, , , ) = priceFeed.stablePriceCheck();
        // 从chainlink返回的价格是8位小数
        return uint256(price) * ADDITIONAL_FEED_PRECISION * amount / PRECISON;
    }

    function getAccountInformation(address user) external view returns(uint256, uint256) {
        return _getAccountInformation(user);
    }

    function getCollateralTokens() external view returns(address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns(uint256) {
        return s_collateralDeposited[user][token];
    }

    function getEthUsdPriceFeed() external view returns(address) {
        return s_priceFeeds[address(0)];
    }
}
