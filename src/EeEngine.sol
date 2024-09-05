// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {EeStableCoin} from "./EeStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin-contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./library/OracleLib.sol";

/**
 * 抵押物Collateral始终大于ee的价值
 */
contract EeEngine is ReentrancyGuard {
    error EeEngine__AmountMustBeMOreThanZero();
    error EeEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error EeEngine__NotAllowToken(address token);
    error EeEngine__TransferFailed();
    error EeEngine__TheHealthFactorBroken(address user);
    error EeEngine__EeMintFailed();
    error EeEngine__HealthFactorOk();
    error EeEngine__HealthFactorNotImproved(uint256 healthFactorValue);

    using OracleLib for AggregatorV3Interface;

    uint256 private constant LIQUIDATION_THRESHOLD = 50; //清算阈值 50%
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;

    // 许可的代币列表
    mapping(address token => address priceFeed) private s_priceFeeds;
    // 用户存入抵押品数量
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    // 用户铸造Ee余额
    mapping(address user => uint256 amountEe) private s_userMintedEe;

    EeStableCoin private immutable i_Ee;

    address[] private s_collateralTokens;
    address[] private s_userAddress;

    event ForceLiquidate(address indexed user);
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    modifier moreThanZero(uint256 amount) {
        if (amount <= 0) {
            revert EeEngine__AmountMustBeMOreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert EeEngine__NotAllowToken(token);
        }
        _;
    }

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address EeAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert EeEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_Ee = EeStableCoin(EeAddress);
    }

    function depositCollateralAndMintEe(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountEeToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintEe(amountEeToMint);
    }

    /**
     * @param tokenCollateralAddress 代币抵押品地址
     * @param amountCollateral The amount of collateral to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        // 存储抵押物
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        // 将抵押品封装为erc20代币, 将存入的代币转移到合约账户
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert EeEngine__TransferFailed();
        }
    }

    // 赎回
    function redeemCollateralForEe(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountEeToBurn)
        external
    {
        // 销毁
        burnEe(amountEeToBurn);
        // 赎回
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    function mintEe(uint256 amountEe) public moreThanZero(amountEe) {
        // 记录用户铸造的Ee
        s_userMintedEe[msg.sender] += amountEe;
        // 如果铸造的Ee超过规定 安全因子，则回滚
        _revertIfHealthFactorIsBroken(msg.sender);
        // 铸造Ee
        bool success = i_Ee.mint(msg.sender, amountEe);
        if (!success) {
            revert EeEngine__EeMintFailed();
        }
        s_userAddress.push(msg.sender);
    }

    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral) public {
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function burnEe(uint256 amountEeToBurn) public moreThanZero(amountEeToBurn) {
        _burnEe(amountEeToBurn, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @param collateralToken 抵押物
     * @param user 欠款人
     * @param debtToCover 需要偿还（覆盖）的债务
     */
    function liquidate(address collateralToken, address user, uint256 debtToCover)
        public
        moreThanZero(debtToCover)
        nonReentrant
    {
        if (_getHealthFactor(user) >= MIN_HEALTH_FACTOR) {
            revert EeEngine__HealthFactorOk();
        }
        // 检查debtToCover 值多少eth/xx
        uint256 tokenAmount = getTokenAmountFromUsd(collateralToken, debtToCover);
        // 计算获取的奖励 = 债务 + 债务 % 10%
        uint256 bonusCollateral = tokenAmount + (tokenAmount * 10) / 100;
        // 赎回奖励给调用者
        _redeemCollateral(collateralToken, bonusCollateral, user, msg.sender);
        // 销毁Ee，
        _burnEe(debtToCover, user, msg.sender);
        // 检查user被清算后的健康因子是否正常，不正常则会滚
        uint256 endHealthFactor = _getHealthFactor(user);

        // 健康因子正常就不用清算
        if (endHealthFactor < MIN_HEALTH_FACTOR) {
            revert EeEngine__HealthFactorNotImproved(endHealthFactor);
        }
        // 检查清算人的健康因子
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @dev 强制清算
     */
    function forceLiquidate() public nonReentrant {
        for (uint256 i = 0; i < s_userAddress.length; i++) {
            address user = s_userAddress[i];
            if (_getHealthFactor(user) >= MIN_HEALTH_FACTOR) {
                continue;
            }
            // 用户债务
            uint256 debtToCover = s_userMintedEe[user];
            // 如果债务已经清算完，跳出循环
            if (debtToCover == 0) {
                continue;
            }
            for (uint256 j = 0; j < s_collateralTokens.length; j++) {
                address collateralToken = s_collateralTokens[j];
                uint256 collateralAmount = s_collateralDeposited[user][collateralToken];
                if (collateralAmount <= 0) {
                    continue;
                }
                // 质押品归零
                s_collateralDeposited[user][s_collateralTokens[j]] = 0;
            }
            i_Ee.burnFrom(user, debtToCover);
            s_userMintedEe[user] = 0;

            emit ForceLiquidate(user);
        }
    }

    /**
     * debtToCover 价值几个 token
     * @param collateralToken token地址
     * @param debtToCover 债务
     */
    function getTokenAmountFromUsd(address collateralToken, uint256 debtToCover)
        public
        view
        returns (uint256 tokenAmount)
    {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[collateralToken]);
        // chainlink预言机返回的价格精度是8位小数
        // 如果价格是 2000.12345678 美元，那么 price 将是 200012345678（以整数形式表示）
        (, int256 price,,,) = priceFeed.latestRoundData();
        // 计算调整了精度，那么在最终结果中恢复精度
        // (uint256(price) * 1e10)：如果价格是 2000.12345678 美元，那么 price 将是 200012345678
        // 再* 1e10就是：2000123456780000000000，此时price相当于2000.12345678 * 1e18
        // 为了使结果不变，那么debtToCover分子也需要 * 1e18
        tokenAmount = ((debtToCover * 1e18) / (uint256(price) * 1e10));
        // 由于 Solidity 中的整数运算会自动向下取整，我们确保 分母 足够大以减少精度损失
    }

    function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address from, address to)
        internal
    {
        if (s_collateralDeposited[from][tokenCollateralAddress] >= amountCollateral) {
            s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        } else {
            s_collateralDeposited[from][tokenCollateralAddress] = 0;
        }

        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        // 将抵押品转账到to账户,从当前合约转移到 to 地址
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert EeEngine__TransferFailed();
        }
    }

    /**
     * @dev 调用此函数，必须先检查健康因子
     * @param amountEeToBurn Ee
     * @param onBehalfOf onBehalfOf 是代表哪个用户减少铸造的 Ee 数量。通常是贷款人的地址
     *          假设用户 A 代表用户 B 销毁 Ee，那么 onBehalfof 就是用户 B 的地址。这个操作是减少用户 B 的 Ee 铸造记录；
     * @param EeFrom 从哪个地址转移 Ee
     */
    function _burnEe(uint256 amountEeToBurn, address onBehalfOf, address EeFrom) internal {
        // 销毁Ee
        s_userMintedEe[onBehalfOf] -= amountEeToBurn;
        // 转账, 将
        bool success = i_Ee.transferFrom(EeFrom, address(this), amountEeToBurn);
        if (!success) {
            revert EeEngine__TransferFailed();
        }
        i_Ee.burn(amountEeToBurn);
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 factor = _getHealthFactor(user);
        if (factor < MIN_HEALTH_FACTOR) {
            revert EeEngine__TheHealthFactorBroken(user);
        }
    }

    // 计算健康因子
    function _getHealthFactor(address user) internal view returns (uint256) {
        (uint256 totalEeMinted, uint256 totCollateralInUsd) = _getAccountInfomation(user);
        if (totalEeMinted == 0) return type(uint256).max;
        // 清算阈值为 LIQUIDATION_THRESHOLD = 50， 说明抵押物必须超多铸造Ee的一半
        // totCollateralInUsd * 50%  然后用一半的totCollateralInUsd除以totalEeMinted得到的值 大于1则说明安全
        uint256 collateralAdjustedForThreshold = (totCollateralInUsd * LIQUIDATION_THRESHOLD) / 100; // 相当于(totCollateralInUsd/100) * 0.5
        return collateralAdjustedForThreshold * MIN_HEALTH_FACTOR / totalEeMinted;
    }

    /**
     *
     * @param user 用户address
     * @return totleEeMinted 用户 mint Ee 数量
     * @return totCollateralInUsd 用户抵押品值多少美元
     */
    function _getAccountInfomation(address user)
        private
        view
        returns (uint256 totleEeMinted, uint256 totCollateralInUsd)
    {
        // 铸造Ee价值
        totleEeMinted = s_userMintedEe[user];
        // 抵押总价值
        totCollateralInUsd = getAccountCollateralValueEe(user);
    }

    function getAccountCollateralValueEe(address user) public view returns (uint256 totCollateralInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            // 获取token的USD价值
            totCollateralInUsd += getUsdValueEe(token, amount);
        }
    }

    function getUsdValueEe(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        // AggregatorV3Interface返回的价格是 1e8
        (, int256 price,,,) = priceFeed.stablePriceLatestRoundData();
        return ((uint256(price) * 1e10) * amount) / 1e18;
    }

    /**
     * 铸造amountEeToMint数量多Ee，需要多少WETH
     * @param wethAddress wethAddress
     * @param amountEeToMint Ee
     */
    function getAmountWethForMintingEe(address wethAddress, uint256 amountEeToMint) public view returns (uint256) {
        uint256 wethUsdValueEee = getUsdValueEe(wethAddress, 1e18);
        uint256 amountWeth = (amountEeToMint * 2 * 1e18) / wethUsdValueEee;
        return amountWeth;
    }

    /////////////////////////////////////
    /////////////测试使用/////////////////
    ////////////////////////////////////
    function getHealthFactor(address user) public view returns (uint256) {
        uint256 factor = _getHealthFactor(user);
        return factor;
    }

    /////////////////////////////////////
    /////////////测试使用/////////////////
    ////////////////////////////////////
    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalEeMinted, uint256 collateralValueInUsd)
    {
        return _getAccountInfomation(user);
    }
}
