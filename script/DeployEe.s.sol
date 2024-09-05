// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {EeEngine} from "../src/EeEngine.sol";
import {EeStableCoin} from "../src/EeStableCoin.sol";
import {HelpConfig} from "./HelpConfig.s.sol";

contract DeployEe is Script {
    address[] private tokenAddresses;
    address[] private priceFeedAddresses;

    struct NetworkConfig {
        address wethUsdPriceFeed;
        address wbtcUsdPriceFeed;
        address weth;
        address wbtc;
        uint256 deployerKey;
    }

    function run() external returns (EeEngine, EeStableCoin, HelpConfig) {
        HelpConfig helpConfig = new HelpConfig();
        (address wethUsdPriceFeed, address wbtcUsdPriceFeed, address weth, address wbtc, uint256 deployerKey) =
            helpConfig.activeNetworkConfig();
        tokenAddresses = [weth, wbtc];
        priceFeedAddresses = [wethUsdPriceFeed, wbtcUsdPriceFeed];
        vm.startBroadcast(deployerKey);
        EeStableCoin ee = new EeStableCoin();
        EeEngine eeEngine = new EeEngine(tokenAddresses, priceFeedAddresses, address(ee));
        // 将ee合约的所有权转让给eeEngine合约
        ee.transferOwnership(address(eeEngine));
        vm.stopBroadcast();
        return (eeEngine, ee, helpConfig);
    }
}
