// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20Burnable, ERC20} from "@openzeppelin-contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin-contracts/access/Ownable.sol";

contract D711StableCoin is ERC20Burnable, Ownable {
    error D711StableCoin__MustBeMoreThanZero();
    error D711StableCoin__BurnAmountExceedsBalance();
    error D711StableCoin__NotZeroAddress();
    error D711StableCoin__CallIsNotD711Engine();

    constructor() ERC20("D711StableCoin", "D711") Ownable(msg.sender) {}

    // 重写 ERC20Burnable.burn(), 销毁代币
    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        // 禁止销毁余额小于等于0
        if (_amount <= 0) {
            revert D711StableCoin__MustBeMoreThanZero();
        }
        // 禁止销毁超过余额的代币
        if (balance < _amount) {
            revert D711StableCoin__BurnAmountExceedsBalance();
        }
        // 销毁代币
        super.burn(_amount);
    }

    // mint铸造代币
    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert D711StableCoin__NotZeroAddress();
        }
        if (_amount <= 0) {
            revert D711StableCoin__MustBeMoreThanZero();
        }
        // _mint为ERC20方法
        _mint(_to, _amount);
        return true;
    }

    function burnFrom(address _from, uint256 _amount) public override onlyOwner {
        if (_amount <= 0) {
            revert D711StableCoin__MustBeMoreThanZero();
        }
        super.burnFrom(_from, _amount);
    }
}
