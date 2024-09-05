// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EeStableCoin} from "./EeStableCoin.sol";
import {EeEngine} from "./EeEngine.sol";
import {Ownable} from "@openzeppelin-contracts/access/Ownable.sol";

contract GameManagement is Ownable {
    error GameManagement__TransferFailed();

    EeStableCoin private immutable i_Ee;

    mapping(uint256 => GameRecord) private s_gameRecordMapping; // 游戏记录
    mapping(address user => uint256 amountEe) private s_playerEeAmount; // 玩家充值余额

    event GameStarted(uint256 indexed roomId);
    event GameEnded(uint256 indexed roomId, address indexed winner);
    event PrizeDistributed(uint256 indexed roomId, address indexed winner, uint256 indexed prizeAmount);
    event EeApproved(address indexed player, uint256 amount);
    event EeTopUp(address indexed player, uint256 amount);
    event EeWithdraw(address indexed player, uint256 amount);

    constructor(address eeAddress) Ownable(msg.sender) {
        i_Ee = EeStableCoin(eeAddress);
    }

    modifier onlyWhenNotStarted(uint256 roomId) {
        require(!s_gameRecordMapping[roomId].isStarted, "Game has already started");
        _;
    }

    modifier onlyWhenStarted(uint256 roomId) {
        require(s_gameRecordMapping[roomId].isStarted, "Game has not started yet");
        _;
    }

    modifier onlyWhenNotEnded(uint256 roomId) {
        require(!s_gameRecordMapping[roomId].isEnded, "Game has already ended");
        _;
    }

    struct GameRecord {
        uint256 roomId;
        bool isStarted;
        bool isEnded;
        address[] playerAddress; // 玩家Address
        uint256[] betAmounts; // 玩家下注金额
        address winner;
        uint256 prizePool;
        uint256 minQualifiedAmount;
    }

    /**
     * @dev 充值方法
     * @param amountEe 充值金额
     */
    function topUpEe(uint256 amountEe) external {
        // 调用此方法需要授权
        bool success = IERC20(i_Ee).transferFrom(msg.sender, address(this), amountEe);
        require(success, "Transfer failed");
        s_playerEeAmount[msg.sender] += amountEe;
        emit EeTopUp(msg.sender, amountEe);
    }

    /**
     * @dev 提现方法
     * @param amountEe 提现金额
     */
    function withdrawEe(uint256 amountEe) external {
        require(amountEe <= s_playerEeAmount[msg.sender], "Insufficient balance");
        s_playerEeAmount[msg.sender] -= amountEe;
        bool success = IERC20(i_Ee).transfer(msg.sender, amountEe);
        require(success, "Transfer failed");
        emit EeWithdraw(msg.sender, amountEe);
    }

    function startGame(uint256 roomId, address[] memory userAddress, uint256 minQualifiedAmount)
        external
        onlyOwner
        onlyWhenNotStarted(roomId)
    {
        require(minQualifiedAmount > 0, "Minimum qualified amount must be greater than 0");
        GameRecord storage record = s_gameRecordMapping[roomId];

        record.roomId = roomId;
        record.isStarted = true;
        record.isEnded = false;
        record.winner = address(0);
        record.prizePool = 0;
        record.minQualifiedAmount = minQualifiedAmount;

        for (uint256 i = 0; i < userAddress.length; i++) {
            address userAddr = userAddress[i];
            require(s_playerEeAmount[userAddr] >= minQualifiedAmount, "Insufficient balance");
            record.playerAddress.push(userAddr);
            // record.betAmount.push(0);
            // 内存中的数组是固定长度的，不能像在 storage 中那样使用 .push() 方法动态扩展
            // players.push(plarer);
        }
        emit GameStarted(roomId);
    }

    function endGame(uint256 roomId, address winner, address[] memory userAddress, uint256[] memory betAmount)
        external
        onlyOwner
        onlyWhenStarted(roomId)
        onlyWhenNotEnded(roomId)
    {
        GameRecord storage record = s_gameRecordMapping[roomId];
        require(record.winner != address(0), "Winner address is zero");
        uint256 prizeAmount = record.prizePool;
        require(prizeAmount > 0, "Prize has been distributed");
        record.isEnded = true;
        record.winner = winner;
        for (uint256 i = 0; i < userAddress.length; i++) {
            address playerAddr = userAddress[i];
            uint256 playerBet = betAmount[i];
            // 更新玩家的下注金额
            for (uint256 j = 0; j < record.playerAddress.length; j++) {
                if (record.playerAddress[j] == playerAddr) {
                    record.betAmounts[j] = playerBet;
                    record.prizePool += playerBet;
                    break;
                }
            }
        }
        // 发放奖励
        for (uint256 i = 0; i < record.playerAddress.length; i++) {
            address playerAddr = record.playerAddress[i];
            uint256 playerBet = record.betAmounts[i];
            if (playerAddr != record.winner) {
                if (s_playerEeAmount[playerAddr] >= playerBet) {
                    s_playerEeAmount[playerAddr] -= playerBet;
                    s_playerEeAmount[record.winner] += playerBet;
                } else {
                    s_playerEeAmount[record.winner] += s_playerEeAmount[playerAddr];
                    s_playerEeAmount[playerAddr] = 0;
                }
            }
        }
        // 更新游戏记录
        s_gameRecordMapping[record.roomId] = record;
        record.prizePool = 0;
        emit PrizeDistributed(record.roomId, record.winner, prizeAmount);
        emit GameEnded(record.roomId, winner);
    }

    function getGameRecord(uint256 roomId) external view returns (GameRecord memory record) {
        record = s_gameRecordMapping[roomId];
    }

    function getPlayerBalance(address userAddr) external view returns (uint256) {
        return s_playerEeAmount[userAddr];
    }
}
