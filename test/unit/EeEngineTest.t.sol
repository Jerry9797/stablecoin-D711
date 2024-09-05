// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {DeployEe} from "../../script/DeployEe.s.sol";
import {HelpConfig} from "../../script/HelpConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "test/mocks/MockV3Aggregator.sol";
import {EeEngine} from "../../src/EeEngine.sol";
import {EeStableCoin} from "../../src/EeStableCoin.sol";

contract EeEngineTest is Test {
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    EeEngine eeEngine;
    EeStableCoin ee;
    HelpConfig helpConfig;

    address wethUsdPriceFeed;
    address wbtcUsdPriceFeed;
    address weth = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address wbtc;
    uint256 deployerKey;

    // 模拟用户
    address public USER = makeAddr("USER");
    // address public USER = 0x4e50e227981C00580aB4765E018A920797e7444A;
    // 清算人
    address public LIQUIDATION_USER = makeAddr("LIQUIDATION_USER");

    uint256 public constant AMOUNT_COLLATERAL = 1 ether; // test指定 1eth = 2000$
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant AMOUNT_MINT = 1000 * 1e18; // 铸造 1000个 711

    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; //清算阈值 50%

    function setUp() public {
        // 获取部署合约
        DeployEe deployEe = new DeployEe();
        (eeEngine, ee, helpConfig) = deployEe.run();
        (wethUsdPriceFeed, wbtcUsdPriceFeed, weth, wbtc, deployerKey) = helpConfig.activeNetworkConfig();
        console.log("eeEngine", address(eeEngine));
        // 给用户铸造一些weth，用于测试
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
        ERC20Mock(weth).mint(LIQUIDATION_USER, 20 ether);
    }

    function testGetUsdValue() public view {
        uint256 value = eeEngine.getUsdValueEe(weth, 1e18);
        // 1e18 * 2000/ETH
        assertEq(value, 2000 * 1e18);
    }

    function testGetAccountCollateralValue() public view {
        uint256 totCollateralInUsd = eeEngine.getAccountCollateralValueEe(USER);
        assertEq(totCollateralInUsd, 0);
    }

    function testReversIfCollateralZero() public {
        vm.startPrank(USER);
        // USER授权合约转账
        ERC20Mock(weth).approve(address(eeEngine), AMOUNT_COLLATERAL);
        vm.expectRevert(EeEngine.EeEngine__AmountMustBeMOreThanZero.selector);
        eeEngine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testIsAllowedToken() public {
        vm.startPrank(USER);
        ERC20Mock test = new ERC20Mock();
        test.mint(USER, STARTING_ERC20_BALANCE);
        vm.expectRevert(abi.encodeWithSelector(EeEngine.EeEngine__NotAllowToken.selector, address(test)));
        eeEngine.depositCollateral(address(test), STARTING_ERC20_BALANCE);
        vm.stopPrank();
    }

    function testGetTokenAmountFromUsd() public view {
        // 1 个代币 = 1e18 个最小单位
        uint256 usdAmount = 100 * 1e18; // 100$
        uint256 tokenAmount = eeEngine.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(tokenAmount, 0.05 ether);
    }

    //////////////// 测试功能逻辑是否符合预期//////////

    modifier depositCollateral() {
        vm.startPrank(USER);
        // 授权合约转账
        ERC20Mock(weth).approve(address(eeEngine), AMOUNT_COLLATERAL);
        eeEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    // 存入抵押品，查询账户余额
    function testCanDepositedCollateralAndGetAccountInfo() public depositCollateral {
        (uint256 totalEeMinted, uint256 collateralValueInUsd) = eeEngine.getAccountInformation(USER);
        assertEq(totalEeMinted, 0);
        uint256 expectedCollateralValueInUsd = eeEngine.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(expectedCollateralValueInUsd, AMOUNT_COLLATERAL);
    }

    // 检查存入抵押品是否成功触发事件
    function testEmitDepositedCollateral() public {
        /**
         *  vm.expectEmit 参数解释
         *  1.	checkTopic1 (bool): 是否检查事件的第一个主题（topic1）。
         * 	2.	checkTopic2 (bool): 是否检查事件的第二个主题（topic2）。
         * 	3.	checkTopic3 (bool): 是否检查事件的第三个主题（topic3）。
         * 	4.	checkData (bool): 是否检查事件的数据部分。
         * 	5.	emitter (address): 期望触发事件的合约地址。
         */
        // 检查是否触发事件
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(eeEngine), AMOUNT_COLLATERAL);
        // ERC20Mock(weth).approve 也会触发一个事件，使用不能放到它前边
        vm.expectEmit(true, true, true, true, address(eeEngine));
        emit CollateralDeposited(USER, weth, AMOUNT_COLLATERAL);
        eeEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testMintEe() public depositCollateral {
        vm.startPrank(USER);
        // 1 ether = 2000 USD, 根据healthFactor,抵押不能过半所以 2000/2 = 1000
        eeEngine.mintEe(10 * 1e18 * 1000);
        uint256 factor = eeEngine.getHealthFactor(USER);
        console.log("factor", factor);
        // depositCollateral抵押了10 ether, eeEngine.depositCollateral(weth, 10 ether),
        // 1 weth = 2000 USD, 铸造 1000个Ee, factor将等于MIN_HEALTH_FACTOR
        assertEq(factor, MIN_HEALTH_FACTOR);

        // 查询账户信息
        (uint256 totalEeMinted,) = eeEngine.getAccountInformation(USER);
        assertEq(totalEeMinted, 10 * 1e18 * 1000);
        vm.stopPrank();
    }

    // 测试mint打破healthFactor
    function testMintBrokenHealthFactor() public depositCollateral {
        // eeEngine.depositCollateral(weth, 1e18)
        vm.startPrank(USER);
        vm.expectRevert(abi.encodeWithSelector(EeEngine.EeEngine__TheHealthFactorBroken.selector, USER));
        eeEngine.mintEe(10 * 1e18 * 2000);
        vm.stopPrank();
    }

    modifier depositedCollateralAndMintedEe(address user) {
        vm.startPrank(user);

        // 给用户铸造一些weth，用于测试
        // ERC20Mock(weth).mint(user, STARTING_ERC20_BALANCE);
        console.log("WETH address:", weth);
        uint256 balance = ERC20Mock(weth).balanceOf(user);
        console.log("WETH balance:", balance);

        // 授权合约转账
        ERC20Mock(weth).approve(address(eeEngine), AMOUNT_COLLATERAL);
        eeEngine.depositCollateralAndMintEe(weth, AMOUNT_COLLATERAL, AMOUNT_MINT);
        uint256 balance1 = ERC20Mock(address(ee)).balanceOf(user);
        console.log("Ee balance:", balance1);
        vm.stopPrank();
        _;
    }

    function testBurnEe() public depositedCollateralAndMintedEe(USER) {
        vm.startPrank(USER);
        // burnEe有交易，所以要授权；
        // ERC20Mock(address(Ee)).approve(address(EeEngine), AMOUNT_MINT);
        // eeEngine.burnEe(AMOUNT_MINT);
        // (uint256 totalEeMinted,) = eeEngine.getAccountInformation(USER);
        // assertEq(totalEeMinted, 0);
        vm.stopPrank();
    }

    function testRedeemCollateral() public depositedCollateralAndMintedEe(USER) {
        vm.startPrank(USER);
        // burnEe有交易，所以要授权；
        ERC20Mock(address(ee)).approve(address(eeEngine), AMOUNT_MINT);
        eeEngine.burnEe(AMOUNT_MINT);

        // 监听事件
        vm.expectEmit(true, true, true, true, address(eeEngine));
        emit CollateralRedeemed(USER, USER, weth, AMOUNT_COLLATERAL);
        eeEngine.redeemCollateral(weth, AMOUNT_COLLATERAL);

        (uint256 totalEeMinted, uint256 collateralValueInUsd) = eeEngine.getAccountInformation(USER);
        console.log("totalEeMinted", totalEeMinted);
        console.log("collateralValueInUsd", collateralValueInUsd);
        assertEq(totalEeMinted, 0);
        assertEq(collateralValueInUsd, 0);
        vm.stopPrank();
    }

    function testLiquidation() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(eeEngine), AMOUNT_COLLATERAL);
        eeEngine.depositCollateralAndMintEe(weth, AMOUNT_COLLATERAL, AMOUNT_MINT);
        vm.stopPrank(); // 10 ether = 100 * 1e18 Ee
        uint256 healthFactorStart = eeEngine.getHealthFactor(USER);
        console.log("healthFactorStart", healthFactorStart);
        (uint256 totalEeMinted, uint256 collateralValueInUsd) = eeEngine.getAccountInformation(USER);
        console.log("USER totalEeMinted", totalEeMinted);
        console.log("USER collateralValueInUsd", collateralValueInUsd);
        // 模拟抵押品价值下降
        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(10e8);

        (uint256 totalEeMinted1, uint256 collateralValueInUsd1) = eeEngine.getAccountInformation(USER);
        console.log("USER totalEeMinted11", totalEeMinted1);
        console.log("USER collateralValueInUsd11", collateralValueInUsd1);

        // 清算前，计算健康因子
        uint256 healthFactorReduce = eeEngine.getHealthFactor(USER);
        console.log("healthFactorReduce", healthFactorReduce);
        assert(healthFactorReduce < 1 ether);
        vm.stopPrank();

        ERC20Mock(weth).mint(LIQUIDATION_USER, collateralToCover);
        vm.startPrank(LIQUIDATION_USER);
        // 授权合约转账
        ERC20Mock(weth).approve(address(eeEngine), 20 ether);
        eeEngine.depositCollateralAndMintEe(weth, 20 ether, AMOUNT_MINT);
        (uint256 totalEeMinted12, uint256 collateralValueInUsd12) = eeEngine.getAccountInformation(USER);
        console.log("LIQUIDATION_USER totalEeMinted11", totalEeMinted12);
        console.log("LIQUIDATION_USER collateralValueInUsd11", collateralValueInUsd12);
        ee.approve(address(eeEngine), AMOUNT_MINT);
        eeEngine.liquidate(weth, USER, AMOUNT_MINT); // AMOUNT_MINT = 100 ether;
        uint256 healthFactorReduce1 = eeEngine.getHealthFactor(USER);
        console.log("healthFactorReduce1", healthFactorReduce1);
        vm.stopPrank();
    }

    // Liquidation
    address public LIQUIDATOR = makeAddr("liquidator");
    uint256 public collateralToCover = 20 ether;

    modifier liquidated() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(eeEngine), AMOUNT_COLLATERAL);
        eeEngine.depositCollateralAndMintEe(weth, AMOUNT_COLLATERAL, AMOUNT_MINT);
        vm.stopPrank();
        // 降价
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 userHealthFactor = eeEngine.getHealthFactor(USER);
        console.log("userHealthFactor", userHealthFactor);

        // 清算
        ERC20Mock(weth).mint(LIQUIDATOR, collateralToCover);

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(eeEngine), collateralToCover);
        eeEngine.depositCollateralAndMintEe(weth, collateralToCover, AMOUNT_MINT);
        ee.approve(address(eeEngine), AMOUNT_MINT);

        eeEngine.liquidate(weth, USER, AMOUNT_MINT); // We are covering their whole debt
        uint256 userHealthFactor1 = eeEngine.getHealthFactor(USER);
        console.log("userHealthFactor1", userHealthFactor1);
        vm.stopPrank();
        _;
    }

    function testLiquidationPayoutIsCorrect() public liquidated {
        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(LIQUIDATOR);
        uint256 expectedWeth =
            eeEngine.getTokenAmountFromUsd(weth, AMOUNT_MINT) + (eeEngine.getTokenAmountFromUsd(weth, AMOUNT_MINT) / 10);
        uint256 hardCodedExpected = 6_111_111_111_111_111_110;
        assertEq(liquidatorWethBalance, hardCodedExpected);
        assertEq(liquidatorWethBalance, expectedWeth);
    }

    function testGetRequiredWethForMintingEe() public {
        vm.startPrank(USER);
        uint256 wethAmount = eeEngine.getAmountWethForMintingEe(weth, 67 * 1e18);
        console.log("wethAmount: ", wethAmount);
        // 10 000000000000000000

        (uint256 totalEeMinted, uint256 collateralValueInUsd) = eeEngine.getAccountInformation(USER);
        console.log("totalEeMinted: ", totalEeMinted);
        console.log("collateralValueInUsd: ", collateralValueInUsd);
        //  0.067000000000000000
        // 67000000000000000
        ERC20Mock(weth).approve(address(eeEngine), wethAmount);
        eeEngine.depositCollateralAndMintEe(weth, wethAmount, 67 * 1e18);
        // (uint256 totalEeMinted, uint256 collateralValueInUsd) = eeEngine.getAccountInformation(USER);
        // console.log("totalEeMinted: ", totalEeMinted);
        // console.log("collateralValueInUsd: ", collateralValueInUsd);
        assertEq(totalEeMinted, 67 * 1e18);
        assertEq(collateralValueInUsd, wethAmount * 2000);
        vm.stopPrank();
    }

    function testBurnEeNotAppove() public {
        vm.startPrank(USER);
        // 铸造前需要用户将Ee代币授权给EeEngine合约，用来强制清算
        ee.approve(address(eeEngine), type(uint256).max);
        ERC20Mock(weth).approve(address(eeEngine), AMOUNT_COLLATERAL);
        eeEngine.depositCollateralAndMintEe(weth, AMOUNT_COLLATERAL, AMOUNT_MINT);
        // 降价
        int256 ethUsdUpdatedPrice = 1000e8;
        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        vm.stopPrank();

        eeEngine.forceLiquidate();

        uint256 balanceEe = ERC20Mock(address(ee)).balanceOf(USER);
        assertEq(balanceEe, 0);
    }
}
