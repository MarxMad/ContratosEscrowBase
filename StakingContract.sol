// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "./CUToken.sol";

contract StakingContract is ReentrancyGuard, Ownable, Pausable {
    CampusCoin public campusCoin;
    
    // Períodos de staking
    enum StakingPeriod {
        ONE_MONTH,    // 1 mes
        THREE_MONTHS, // 3 meses
        SIX_MONTHS,   // 6 meses
        TWELVE_MONTHS // 12 meses
    }
    
    // APY por período
    mapping(StakingPeriod => uint256) public apyRates;
    
    // Estructura de stake
    struct Stake {
        uint256 amount;
        uint256 startTime;
        uint256 endTime;
        StakingPeriod period;
        bool active;
        uint256 rewardsClaimed;
    }
    
    // Stakes por usuario
    mapping(address => Stake[]) public userStakes;
    mapping(address => uint256) public totalStaked;
    
    // Estadísticas globales
    uint256 public totalStakedAmount;
    uint256 public totalRewardsDistributed;
    uint256 public totalActiveStakes;
    
    // Eventos
    event StakeCreated(
        address indexed user,
        uint256 stakeId,
        uint256 amount,
        StakingPeriod period,
        uint256 endTime
    );
    event StakeUnlocked(
        address indexed user,
        uint256 stakeId,
        uint256 amount,
        uint256 rewards
    );
    event RewardsClaimed(
        address indexed user,
        uint256 stakeId,
        uint256 amount
    );
    event EmergencyUnstake(
        address indexed user,
        uint256 stakeId,
        uint256 amount,
        uint256 penalty
    );
    
    constructor(address _campusCoin) Ownable(msg.sender) {
        require(_campusCoin != address(0), "Invalid token address");
        campusCoin = CampusCoin(_campusCoin);
        
        // Configurar APY rates
        apyRates[StakingPeriod.ONE_MONTH] = 500;    // 5%
        apyRates[StakingPeriod.THREE_MONTHS] = 800;  // 8%
        apyRates[StakingPeriod.SIX_MONTHS] = 1200;   // 12%
        apyRates[StakingPeriod.TWELVE_MONTHS] = 2000; // 20%
    }
    
    // Crear stake
    function stake(uint256 amount, StakingPeriod period) external nonReentrant whenNotPaused {
        require(amount > 0, "Amount must be greater than 0");
        require(campusCoin.balanceOf(msg.sender) >= amount, "Insufficient balance");
        require(campusCoin.allowance(msg.sender, address(this)) >= amount, "Insufficient allowance");
        
        // Transferir tokens al contrato
        require(
            campusCoin.transferFrom(msg.sender, address(this), amount),
            "Transfer failed"
        );
        
        // Calcular tiempo de stake
        uint256 stakeDuration = getStakeDuration(period);
        uint256 endTime = block.timestamp + stakeDuration;
        
        // Crear stake
        Stake memory newStake = Stake({
            amount: amount,
            startTime: block.timestamp,
            endTime: endTime,
            period: period,
            active: true,
            rewardsClaimed: 0
        });
        
        userStakes[msg.sender].push(newStake);
        uint256 stakeId = userStakes[msg.sender].length - 1;
        
        // Actualizar estadísticas
        totalStakedAmount += amount;
        totalActiveStakes++;
        totalStaked[msg.sender] += amount;
        
        emit StakeCreated(msg.sender, stakeId, amount, period, endTime);
    }
    
    // Desbloquear stake
    function unstake(uint256 stakeId) external nonReentrant {
        require(stakeId < userStakes[msg.sender].length, "Invalid stake ID");
        Stake storage stakeInfo = userStakes[msg.sender][stakeId];
        require(stakeInfo.active, "Stake not active");
        require(block.timestamp >= stakeInfo.endTime, "Stake not mature");
        
        uint256 amount = stakeInfo.amount;
        uint256 rewards = calculateRewards(msg.sender, stakeId);
        
        // Marcar como inactivo
        stakeInfo.active = false;
        
        // Actualizar estadísticas
        totalStakedAmount -= amount;
        totalActiveStakes--;
        totalStaked[msg.sender] -= amount;
        totalRewardsDistributed += rewards;
        
        // Transferir tokens + recompensas
        require(
            campusCoin.transfer(msg.sender, amount + rewards),
            "Transfer failed"
        );
        
        emit StakeUnlocked(msg.sender, stakeId, amount, rewards);
    }
    
    // Reclamar recompensas (sin desbloquear stake)
    function claimRewards(uint256 stakeId) external nonReentrant {
        require(stakeId < userStakes[msg.sender].length, "Invalid stake ID");
        Stake storage stakeInfo = userStakes[msg.sender][stakeId];
        require(stakeInfo.active, "Stake not active");
        
        uint256 rewards = calculateRewards(msg.sender, stakeId);
        require(rewards > 0, "No rewards to claim");
        
        // Actualizar recompensas reclamadas
        stakeInfo.rewardsClaimed += rewards;
        totalRewardsDistributed += rewards;
        
        // Transferir recompensas
        require(
            campusCoin.transfer(msg.sender, rewards),
            "Transfer failed"
        );
        
        emit RewardsClaimed(msg.sender, stakeId, rewards);
    }
    
    // Desbloqueo de emergencia (con penalización)
    function emergencyUnstake(uint256 stakeId) external nonReentrant {
        require(stakeId < userStakes[msg.sender].length, "Invalid stake ID");
        Stake storage stakeInfo = userStakes[msg.sender][stakeId];
        require(stakeInfo.active, "Stake not active");
        
        uint256 amount = stakeInfo.amount;
        uint256 penalty = amount / 10; // 10% de penalización
        uint256 returnedAmount = amount - penalty;
        
        // Marcar como inactivo
        stakeInfo.active = false;
        
        // Actualizar estadísticas
        totalStakedAmount -= amount;
        totalActiveStakes--;
        totalStaked[msg.sender] -= amount;
        
        // Transferir tokens (menos penalización)
        require(
            campusCoin.transfer(msg.sender, returnedAmount),
            "Transfer failed"
        );
        
        // Quemar penalización
        require(
            campusCoin.burn(penalty),
            "Burn failed"
        );
        
        emit EmergencyUnstake(msg.sender, stakeId, returnedAmount, penalty);
    }
    
    // Calcular recompensas acumuladas
    function calculateRewards(address user, uint256 stakeId) public view returns (uint256) {
        if (stakeId >= userStakes[user].length) return 0;
        
        Stake memory stakeInfo = userStakes[user][stakeId];
        if (!stakeInfo.active) return 0;
        
        uint256 timeStaked = block.timestamp - stakeInfo.startTime;
        uint256 apy = apyRates[stakeInfo.period];
        
        // Calcular recompensas: (amount * apy * timeStaked) / (365 days * 10000)
        uint256 rewards = (stakeInfo.amount * apy * timeStaked) / (365 days * 10000);
        
        return rewards - stakeInfo.rewardsClaimed;
    }
    
    // Obtener duración del stake
    function getStakeDuration(StakingPeriod period) public pure returns (uint256) {
        if (period == StakingPeriod.ONE_MONTH) return 30 days;
        if (period == StakingPeriod.THREE_MONTHS) return 90 days;
        if (period == StakingPeriod.SIX_MONTHS) return 180 days;
        if (period == StakingPeriod.TWELVE_MONTHS) return 365 days;
        return 0;
    }
    
    // Obtener stakes de un usuario
    function getUserStakes(address user) external view returns (Stake[] memory) {
        return userStakes[user];
    }
    
    // Obtener stake específico
    function getUserStake(address user, uint256 stakeId) external view returns (Stake memory) {
        require(stakeId < userStakes[user].length, "Invalid stake ID");
        return userStakes[user][stakeId];
    }
    
    // Obtener estadísticas del usuario
    function getUserStats(address user) external view returns (
        uint256 totalStaked_,
        uint256 totalRewards_,
        uint256 activeStakes_,
        uint256 totalRewardsClaimed_
    ) {
        totalStaked_ = totalStaked[user];
        activeStakes_ = 0;
        totalRewards_ = 0;
        totalRewardsClaimed_ = 0;
        
        for (uint256 i = 0; i < userStakes[user].length; i++) {
            Stake memory stakeInfo = userStakes[user][i];
            if (stakeInfo.active) {
                activeStakes_++;
                totalRewards_ += calculateRewards(user, i);
            }
            totalRewardsClaimed_ += stakeInfo.rewardsClaimed;
        }
    }
    
    // Obtener estadísticas globales
    function getGlobalStats() external view returns (
        uint256 totalStakedAmount_,
        uint256 totalRewardsDistributed_,
        uint256 totalActiveStakes_,
        uint256 availableRewards_
    ) {
        totalStakedAmount_ = totalStakedAmount;
        totalRewardsDistributed_ = totalRewardsDistributed;
        totalActiveStakes_ = totalActiveStakes;
        availableRewards_ = campusCoin.balanceOf(address(this)) - totalStakedAmount;
    }
    
    // Actualizar APY rates (solo owner)
    function setAPYRate(StakingPeriod period, uint256 newRate) external onlyOwner {
        require(newRate <= 5000, "APY too high"); // Máximo 50%
        apyRates[period] = newRate;
    }
    
    // Función de pausa de emergencia
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
    
    // Función de emergencia para recuperar tokens
    function emergencyWithdraw(uint256 amount) external onlyOwner {
        require(amount <= campusCoin.balanceOf(address(this)), "Insufficient balance");
        require(campusCoin.transfer(owner(), amount), "Transfer failed");
    }
}
