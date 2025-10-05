// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./CUToken.sol";

contract ProductEscrowFactory is Ownable, ReentrancyGuard {
    CampusCoin public campusCoin;
    
    // Estructura para categorías de productos
    enum ProductCategory {
        BOOKS,
        ELECTRONICS,
        CLOTHING,
        SPORTS,
        HOME,
        OTHER
    }
    
    // Mapeo de escrows por producto
    mapping(uint256 => address) public productEscrows;
    mapping(address => bool) public isEscrowContract;
    
    // Arrays para tracking
    uint256[] public allProductIds;
    address[] public allEscrowContracts;
    
    // Eventos
    event ProductEscrowCreated(
        uint256 indexed productId,
        address indexed escrowContract,
        address indexed seller,
        ProductCategory category,
        uint256 price
    );
    event ProductSold(uint256 indexed productId, address indexed buyer);
    event ProductDelivered(uint256 indexed productId, address indexed buyer);
    
    constructor(address _campusCoin) Ownable(msg.sender) {
        campusCoin = CampusCoin(_campusCoin);
    }
    
    // Crear nuevo escrow para un producto
    function createProductEscrow(
        string memory productName,
        string memory productDescription,
        string memory imageURI,
        uint256 price,
        ProductCategory category,
        uint256 deliveryTimeHours
    ) external nonReentrant returns (address) {
        require(price > 0, "Price must be greater than 0");
        require(deliveryTimeHours > 0, "Delivery time must be specified");
        
        // Crear nuevo ID de producto
        uint256 productId = allProductIds.length + 1;
        
        // Crear nuevo contrato de escrow
        ProductEscrow newEscrow = new ProductEscrow(
            productId,
            msg.sender,
            productName,
            productDescription,
            imageURI,
            price,
            category,
            deliveryTimeHours,
            address(campusCoin),
            address(this)
        );
        
        // Registrar el escrow
        productEscrows[productId] = address(newEscrow);
        isEscrowContract[address(newEscrow)] = true;
        allProductIds.push(productId);
        allEscrowContracts.push(address(newEscrow));
        
        emit ProductEscrowCreated(
            productId,
            address(newEscrow),
            msg.sender,
            category,
            price
        );
        
        return address(newEscrow);
    }
    
    // Comprar producto
    function buyProduct(uint256 productId) external nonReentrant {
        address escrowAddress = productEscrows[productId];
        require(escrowAddress != address(0), "Product does not exist");
        
        ProductEscrow escrow = ProductEscrow(escrowAddress);
        escrow.buy(msg.sender);
        
        emit ProductSold(productId, msg.sender);
    }
    
    // Confirmar entrega
    function confirmDelivery(uint256 productId) external nonReentrant {
        address escrowAddress = productEscrows[productId];
        require(escrowAddress != address(0), "Product does not exist");
        
        ProductEscrow escrow = ProductEscrow(escrowAddress);
        escrow.confirmDelivery(msg.sender);
        
        emit ProductDelivered(productId, msg.sender);
    }
    
    // Cancelar transacción (solo en casos especiales)
    function cancelTransaction(uint256 productId, string memory reason) external onlyOwner {
        address escrowAddress = productEscrows[productId];
        require(escrowAddress != address(0), "Product does not exist");
        
        ProductEscrow escrow = ProductEscrow(escrowAddress);
        escrow.emergencyCancel(reason);
    }
    
    // Funciones de consulta
    function getAllProducts() external view returns (
        uint256[] memory productIds,
        address[] memory escrowAddresses,
        address[] memory sellers,
        uint256[] memory prices,
        ProductCategory[] memory categories
    ) {
        uint256 length = allProductIds.length;
        productIds = new uint256[](length);
        escrowAddresses = new address[](length);
        sellers = new address[](length);
        prices = new uint256[](length);
        categories = new ProductCategory[](length);
        
        for (uint256 i = 0; i < length; i++) {
            uint256 productId = allProductIds[i];
            address escrowAddress = productEscrows[productId];
            ProductEscrow escrow = ProductEscrow(escrowAddress);
            
            productIds[i] = productId;
            escrowAddresses[i] = escrowAddress;
            sellers[i] = escrow.seller();
            prices[i] = escrow.price();
            categories[i] = escrow.category();
        }
    }
    
    function getProductsByCategory(ProductCategory category) external view returns (uint256[] memory) {
        uint256 count = 0;
        for (uint256 i = 0; i < allProductIds.length; i++) {
            address escrowAddress = productEscrows[allProductIds[i]];
            ProductEscrow escrow = ProductEscrow(escrowAddress);
            if (escrow.category() == category) {
                count++;
            }
        }
        
        uint256[] memory products = new uint256[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < allProductIds.length; i++) {
            address escrowAddress = productEscrows[allProductIds[i]];
            ProductEscrow escrow = ProductEscrow(escrowAddress);
            if (escrow.category() == category) {
                products[index] = allProductIds[i];
                index++;
            }
        }
        return products;
    }
    
    function getMyProducts(address user) external view returns (uint256[] memory) {
        uint256 count = 0;
        for (uint256 i = 0; i < allProductIds.length; i++) {
            address escrowAddress = productEscrows[allProductIds[i]];
            ProductEscrow escrow = ProductEscrow(escrowAddress);
            if (escrow.seller() == user) {
                count++;
            }
        }
        
        uint256[] memory myProducts = new uint256[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < allProductIds.length; i++) {
            address escrowAddress = productEscrows[allProductIds[i]];
            ProductEscrow escrow = ProductEscrow(escrowAddress);
            if (escrow.seller() == user) {
                myProducts[index] = allProductIds[i];
                index++;
            }
        }
        return myProducts;
    }
    
    function getMyPurchases(address user) external view returns (uint256[] memory) {
        uint256 count = 0;
        for (uint256 i = 0; i < allProductIds.length; i++) {
            address escrowAddress = productEscrows[allProductIds[i]];
            ProductEscrow escrow = ProductEscrow(escrowAddress);
            if (escrow.buyer() == user) {
                count++;
            }
        }
        
        uint256[] memory myPurchases = new uint256[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < allProductIds.length; i++) {
            address escrowAddress = productEscrows[allProductIds[i]];
            ProductEscrow escrow = ProductEscrow(escrowAddress);
            if (escrow.buyer() == user) {
                myPurchases[index] = allProductIds[i];
                index++;
            }
        }
        return myPurchases;
    }
}
