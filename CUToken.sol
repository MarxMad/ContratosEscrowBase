// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract CampusCoin is ERC20, Ownable, Pausable, ReentrancyGuard {
    // Límites de seguridad
    uint256 public constant MAX_SUPPLY = 10_000_000 * 10**18; // 10M tokens máximo
    uint256 public constant MAX_MINT_AMOUNT = 100_000 * 10**18; // 100K tokens por mint
    uint256 public constant INITIAL_SUPPLY = 1_000_000 * 10**18; // 1M tokens iniciales
    
    // Eventos personalizados
    event TokensMinted(address indexed to, uint256 amount);
    event TokensBurned(address indexed from, uint256 amount);
    event EmergencyPause();
    event EmergencyUnpause();
    
    constructor() ERC20("CampusCoin", "CC") Ownable(msg.sender) {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
    
    // Función de mint mejorada con validaciones
    function mint(address to, uint256 amount) public onlyOwner whenNotPaused {
        require(to != address(0), "Cannot mint to zero address");
        require(amount > 0, "Amount must be greater than 0");
        require(amount <= MAX_MINT_AMOUNT, "Amount exceeds maximum mint limit");
        require(totalSupply() + amount <= MAX_SUPPLY, "Would exceed maximum supply");
        
        _mint(to, amount);
        emit TokensMinted(to, amount);
    }
    
    // Función para quemar tokens
    function burn(uint256 amount) public whenNotPaused {
        require(amount > 0, "Amount must be greater than 0");
        require(balanceOf(msg.sender) >= amount, "Insufficient balance to burn");
        
        _burn(msg.sender, amount);
        emit TokensBurned(msg.sender, amount);
    }
    
    // Función para quemar tokens de otro usuario (solo owner)
    function burnFrom(address account, uint256 amount) public onlyOwner whenNotPaused {
        require(account != address(0), "Cannot burn from zero address");
        require(amount > 0, "Amount must be greater than 0");
        require(balanceOf(account) >= amount, "Insufficient balance to burn");
        
        _burn(account, amount);
        emit TokensBurned(account, amount);
    }
    
    // Función de pausa de emergencia
    function pause() public onlyOwner {
        _pause();
        emit EmergencyPause();
    }
    
    function unpause() public onlyOwner {
        _unpause();
        emit EmergencyUnpause();
    }
    
    // Override de transfer con pausa
    function _update(address from, address to, uint256 value) internal override whenNotPaused {
        super._update(from, to, value);
    }
    
    // Función para obtener estadísticas del token
    function getTokenStats() external view returns (
        uint256 totalSupply_,
        uint256 maxSupply_,
        uint256 maxMintAmount_,
        bool paused_
    ) {
        return (
            totalSupply(),
            MAX_SUPPLY,
            MAX_MINT_AMOUNT,
            paused()
        );
    }
    
    // Función para verificar si se puede mintear una cantidad
    function canMint(uint256 amount) external view returns (bool, string memory) {
        if (amount == 0) {
            return (false, "Amount must be greater than 0");
        }
        if (amount > MAX_MINT_AMOUNT) {
            return (false, "Amount exceeds maximum mint limit");
        }
        if (totalSupply() + amount > MAX_SUPPLY) {
            return (false, "Would exceed maximum supply");
        }
        return (true, "Can mint");
    }
    
    // Función de emergencia para recuperar tokens perdidos
    function emergencyRecover(address token, uint256 amount) external onlyOwner {
        require(token != address(this), "Cannot recover own tokens");
        require(token != address(0), "Invalid token address");
        require(amount > 0, "Amount must be greater than 0");
        
        // Esta función sería para recuperar otros tokens ERC20 que puedan quedar atrapados
        // La implementación específica dependería del token a recuperar
    }
}