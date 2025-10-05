// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "./CUToken.sol";

contract ProductEscrowFactoryFixed is Ownable, ReentrancyGuard, Pausable {
    CampusCoin public campusCoin;
    
    // Contador atómico para IDs únicos
    uint256 private _nextProductId = 1;
    
    // Límites de seguridad
    uint256 public constant MAX_PRICE = 1000000 * 10**18; // 1M tokens máximo
    uint256 public constant MAX_DELIVERY_TIME = 30 * 24; // 30 días máximo
    uint256 public constant MIN_DELIVERY_TIME = 1; // 1 hora mínimo
    uint256 public constant MAX_STRING_LENGTH = 1000; // 1000 caracteres máximo
    
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
    event ProductCancelled(uint256 indexed productId, string reason);
    
    constructor(address _campusCoin) Ownable(msg.sender) {
        require(_campusCoin != address(0), "Invalid token address");
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
    ) external nonReentrant whenNotPaused returns (address) {
        // Validaciones de entrada
        require(bytes(productName).length > 0, "Product name required");
        require(bytes(productName).length <= MAX_STRING_LENGTH, "Product name too long");
        require(bytes(productDescription).length <= MAX_STRING_LENGTH, "Description too long");
        require(bytes(imageURI).length <= MAX_STRING_LENGTH, "Image URI too long");
        require(price > 0, "Price must be greater than 0");
        require(price <= MAX_PRICE, "Price too high");
        require(deliveryTimeHours >= MIN_DELIVERY_TIME, "Delivery time too short");
        require(deliveryTimeHours <= MAX_DELIVERY_TIME, "Delivery time too long");
        
        // Generar ID único de forma segura
        uint256 productId = _nextProductId;
        _nextProductId++;
        
        // Crear nuevo contrato de escrow
        ProductEscrowFixed newEscrow = new ProductEscrowFixed(
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
    
    // Comprar producto con validación de allowance
    function buyProduct(uint256 productId) external nonReentrant whenNotPaused {
        address escrowAddress = productEscrows[productId];
        require(escrowAddress != address(0), "Product does not exist");
        
        ProductEscrowFixed escrow = ProductEscrowFixed(escrowAddress);
        
        // Verificar allowance antes de intentar comprar
        require(
            campusCoin.allowance(msg.sender, address(escrow)) >= escrow.price(),
            "Insufficient allowance"
        );
        
        escrow.buy(msg.sender);
        
        emit ProductSold(productId, msg.sender);
    }
    
    // Confirmar entrega
    function confirmDelivery(uint256 productId) external nonReentrant whenNotPaused {
        address escrowAddress = productEscrows[productId];
        require(escrowAddress != address(0), "Product does not exist");
        
        ProductEscrowFixed escrow = ProductEscrowFixed(escrowAddress);
        escrow.confirmDelivery(msg.sender);
        
        emit ProductDelivered(productId, msg.sender);
    }
    
    // Cancelar transacción (solo en casos especiales)
    function cancelTransaction(uint256 productId, string memory reason) external onlyOwner {
        address escrowAddress = productEscrows[productId];
        require(escrowAddress != address(0), "Product does not exist");
        require(bytes(reason).length > 0, "Reason required");
        
        ProductEscrowFixed escrow = ProductEscrowFixed(escrowAddress);
        escrow.emergencyCancel(reason);
        
        emit ProductCancelled(productId, reason);
    }
    
    // Función de pausa de emergencia
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
    
    // Funciones de consulta optimizadas (con límites)
    function getAllProducts(uint256 limit, uint256 offset) external view returns (
        uint256[] memory productIds,
        address[] memory escrowAddresses,
        address[] memory sellers,
        uint256[] memory prices,
        ProductCategory[] memory categories
    ) {
        require(limit > 0 && limit <= 100, "Invalid limit");
        require(offset < allProductIds.length, "Invalid offset");
        
        uint256 length = allProductIds.length;
        uint256 end = offset + limit;
        if (end > length) end = length;
        
        uint256 resultLength = end - offset;
        productIds = new uint256[](resultLength);
        escrowAddresses = new address[](resultLength);
        sellers = new address[](resultLength);
        prices = new uint256[](resultLength);
        categories = new ProductCategory[](resultLength);
        
        for (uint256 i = offset; i < end; i++) {
            uint256 productId = allProductIds[i];
            address escrowAddress = productEscrows[productId];
            ProductEscrowFixed escrow = ProductEscrowFixed(escrowAddress);
            
            uint256 index = i - offset;
            productIds[index] = productId;
            escrowAddresses[index] = escrowAddress;
            sellers[index] = escrow.seller();
            prices[index] = escrow.price();
            categories[index] = escrow.category();
        }
    }
    
    function getProductsByCategory(ProductCategory category, uint256 limit) external view returns (uint256[] memory) {
        require(limit > 0 && limit <= 100, "Invalid limit");
        
        uint256 count = 0;
        uint256[] memory tempProducts = new uint256[](allProductIds.length);
        
        for (uint256 i = 0; i < allProductIds.length && count < limit; i++) {
            address escrowAddress = productEscrows[allProductIds[i]];
            ProductEscrowFixed escrow = ProductEscrowFixed(escrowAddress);
            if (escrow.category() == category) {
                tempProducts[count] = allProductIds[i];
                count++;
            }
        }
        
        uint256[] memory products = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            products[i] = tempProducts[i];
        }
        return products;
    }
    
    function getMyProducts(address user, uint256 limit) external view returns (uint256[] memory) {
        require(user != address(0), "Invalid user address");
        require(limit > 0 && limit <= 100, "Invalid limit");
        
        uint256 count = 0;
        uint256[] memory tempProducts = new uint256[](allProductIds.length);
        
        for (uint256 i = 0; i < allProductIds.length && count < limit; i++) {
            address escrowAddress = productEscrows[allProductIds[i]];
            ProductEscrowFixed escrow = ProductEscrowFixed(escrowAddress);
            if (escrow.seller() == user) {
                tempProducts[count] = allProductIds[i];
                count++;
            }
        }
        
        uint256[] memory myProducts = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            myProducts[i] = tempProducts[i];
        }
        return myProducts;
    }
    
    function getMyPurchases(address user, uint256 limit) external view returns (uint256[] memory) {
        require(user != address(0), "Invalid user address");
        require(limit > 0 && limit <= 100, "Invalid limit");
        
        uint256 count = 0;
        uint256[] memory tempPurchases = new uint256[](allProductIds.length);
        
        for (uint256 i = 0; i < allProductIds.length && count < limit; i++) {
            address escrowAddress = productEscrows[allProductIds[i]];
            ProductEscrowFixed escrow = ProductEscrowFixed(escrowAddress);
            if (escrow.buyer() == user) {
                tempPurchases[count] = allProductIds[i];
                count++;
            }
        }
        
        uint256[] memory myPurchases = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            myPurchases[i] = tempPurchases[i];
        }
        return myPurchases;
    }
    
    // Función de emergencia para recuperar tokens
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        require(token != address(0), "Invalid token address");
        require(amount > 0, "Amount must be greater than 0");
        
        if (token == address(campusCoin)) {
            require(campusCoin.transfer(owner(), amount), "Transfer failed");
        }
    }
}
