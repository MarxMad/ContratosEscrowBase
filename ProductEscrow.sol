// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./CUToken.sol";

contract ProductEscrow is ReentrancyGuard, Ownable {
    // Referencias
    CampusCoin public campusCoin;
    address public factory;
    
    // Información del producto
    uint256 public productId;
    string public productName;
    string public productDescription;
    string public imageURI;
    uint256 public price;
    ProductCategory public category;
    uint256 public deliveryTimeHours;
    
    // Partes involucradas
    address public seller;
    address public buyer;
    
    // Estados
    bool public sold;
    bool public delivered;
    bool public cancelled;
    uint256 public purchaseTime;
    uint256 public deliveryDeadline;
    
    // Razón de cancelación
    string public cancellationReason;
    
    // Enums
    enum ProductCategory {
        BOOKS,
        ELECTRONICS,
        CLOTHING,
        SPORTS,
        HOME,
        OTHER
    }
    
    // Eventos
    event ProductPurchased(uint256 indexed productId, address indexed buyer, uint256 price);
    event ProductDelivered(uint256 indexed productId, address indexed buyer);
    event ProductCancelled(uint256 indexed productId, string reason);
    event RefundIssued(uint256 indexed productId, address indexed buyer, uint256 amount);
    
    constructor(
        uint256 _productId,
        address _seller,
        string memory _productName,
        string memory _productDescription,
        string memory _imageURI,
        uint256 _price,
        ProductCategory _category,
        uint256 _deliveryTimeHours,
        address _campusCoin,
        address _factory
    ) Ownable(_factory) {
        productId = _productId;
        seller = _seller;
        productName = _productName;
        productDescription = _productDescription;
        imageURI = _imageURI;
        price = _price;
        category = _category;
        deliveryTimeHours = _deliveryTimeHours;
        campusCoin = CampusCoin(_campusCoin);
        factory = _factory;
    }
    
    // Comprar producto
    function buy(address buyerAddress) external nonReentrant {
        require(msg.sender == factory, "Only factory can call this");
        require(!sold, "Product already sold");
        require(!cancelled, "Product is cancelled");
        require(buyerAddress != seller, "Seller cannot buy their own product");
        
        // Verificar que el comprador tiene suficientes tokens
        require(
            campusCoin.balanceOf(buyerAddress) >= price,
            "Insufficient CampusCoin balance"
        );
        
        // Transferir tokens al contrato (escrow)
        require(
            campusCoin.transferFrom(buyerAddress, address(this), price),
            "Transfer failed"
        );
        
        buyer = buyerAddress;
        sold = true;
        purchaseTime = block.timestamp;
        deliveryDeadline = block.timestamp + (deliveryTimeHours * 1 hours);
        
        emit ProductPurchased(productId, buyerAddress, price);
    }
    
    // Confirmar entrega
    function confirmDelivery(address buyerAddress) external nonReentrant {
        require(msg.sender == factory, "Only factory can call this");
        require(sold, "Product not sold");
        require(!delivered, "Already delivered");
        require(!cancelled, "Product is cancelled");
        require(buyerAddress == buyer, "Only buyer can confirm delivery");
        
        delivered = true;
        
        // Transferir tokens al vendedor
        require(
            campusCoin.transfer(seller, price),
            "Transfer to seller failed"
        );
        
        emit ProductDelivered(productId, buyerAddress);
    }
    
    // Cancelar transacción (solo factory/owner)
    function emergencyCancel(string memory reason) external onlyOwner {
        require(sold, "Product not sold");
        require(!delivered, "Product already delivered");
        require(!cancelled, "Already cancelled");
        
        cancelled = true;
        cancellationReason = reason;
        
        // Reembolsar al comprador si ya compró
        if (buyer != address(0)) {
            require(
                campusCoin.transfer(buyer, price),
                "Refund failed"
            );
            emit RefundIssued(productId, buyer, price);
        }
        
        emit ProductCancelled(productId, reason);
    }
    
    // Reembolso automático si se pasa el tiempo límite
    function requestRefund() external nonReentrant {
        require(sold, "Product not sold");
        require(!delivered, "Product already delivered");
        require(!cancelled, "Product is cancelled");
        require(block.timestamp > deliveryDeadline, "Delivery deadline not passed");
        require(msg.sender == buyer, "Only buyer can request refund");
        
        cancelled = true;
        cancellationReason = "Delivery timeout";
        
        require(
            campusCoin.transfer(buyer, price),
            "Refund failed"
        );
        
        emit RefundIssued(productId, buyer, price);
        emit ProductCancelled(productId, "Delivery timeout");
    }
    
    // Funciones de consulta
    function getProductInfo() external view returns (
        uint256 _productId,
        string memory _productName,
        string memory _productDescription,
        string memory _imageURI,
        uint256 _price,
        ProductCategory _category,
        address _seller,
        address _buyer,
        bool _sold,
        bool _delivered,
        bool _cancelled,
        uint256 _purchaseTime,
        uint256 _deliveryDeadline
    ) {
        return (
            productId,
            productName,
            productDescription,
            imageURI,
            price,
            category,
            seller,
            buyer,
            sold,
            delivered,
            cancelled,
            purchaseTime,
            deliveryDeadline
        );
    }
    
    function isExpired() external view returns (bool) {
        return block.timestamp > deliveryDeadline && sold && !delivered && !cancelled;
    }
    
    function getTimeRemaining() external view returns (uint256) {
        if (block.timestamp >= deliveryDeadline) {
            return 0;
        }
        return deliveryDeadline - block.timestamp;
    }
}
