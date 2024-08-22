// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {D711Engine} from "../src/D711Engine.sol";
import {D711StableCoin} from "../src/D711StableCoin.sol";
import {HelpConfig} from "./HelpConfig.s.sol";

contract DeployD711 is Script {
    address[] private tokenAddresses;
    address[] private priceFeedAddresses;

    struct NetworkConfig {
        address wethUsdPriceFeed;
        address wbtcUsdPriceFeed;
        address weth;
        address wbtc;
        uint256 deployerKey;
    }

    function run() external returns (D711Engine, D711StableCoin, HelpConfig) {
        HelpConfig helpConfig = new HelpConfig();
        (address wethUsdPriceFeed, address wbtcUsdPriceFeed, address weth, address wbtc, uint256 deployerKey) =
            helpConfig.activeNetworkConfig();
        tokenAddresses = [weth, wbtc];
        priceFeedAddresses = [wethUsdPriceFeed, wbtcUsdPriceFeed];
        vm.startBroadcast(deployerKey);
        D711StableCoin d711 = new D711StableCoin();
        D711Engine d711Engine = new D711Engine(tokenAddresses, priceFeedAddresses, address(d711));
        // 将d711合约的所有权转让给d711Engine合约
        d711.transferOwnership(address(d711Engine));
        vm.stopBroadcast();
        return (d711Engine, d711, helpConfig);
    }
}
