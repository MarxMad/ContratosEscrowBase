// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "./CUToken.sol";

contract ProductEscrowFactory is Ownable, ReentrancyGuard, Pausable {
    CampusCoin public campusCoin;
    
    // Comisiones del marketplace
    uint256 public platformFeePercent = 250; // 2.5% (250/10000)
    uint256 public constant MAX_FEE_PERCENT = 1000; // 10% máximo
    address public feeRecipient;
    
    // Límites para decidir si usar escrow individual
    uint256 public constant HIGH_VALUE_THRESHOLD = 10000 * 10**18; // 10K tokens
    uint256 public constant PREMIUM_CATEGORY_FEE = 500; // 5% para categorías premium
    
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
    
    // Estadísticas de comisiones
    uint256 public totalFeesCollected;
    uint256 public totalProductsCreated;
    
    // Eventos
    event ProductEscrowCreated(
        uint256 indexed productId,
        address indexed escrowContract,
        address indexed seller,
        ProductCategory category,
        uint256 price,
        bool isHighValue
    );
    event ProductSold(uint256 indexed productId, address indexed buyer, uint256 price, uint256 fee);
    event ProductDelivered(uint256 indexed productId, address indexed buyer);
    event FeeCollected(uint256 indexed productId, uint256 amount);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event PlatformFeeUpdated(uint256 oldFee, uint256 newFee);
    
    constructor(address _campusCoin, address _feeRecipient) Ownable(msg.sender) {
        require(_campusCoin != address(0), "Invalid token address");
        require(_feeRecipient != address(0), "Invalid fee recipient");
        campusCoin = CampusCoin(_campusCoin);
        feeRecipient = _feeRecipient;
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
        
        // Determinar si es producto de alto valor
        bool isHighValue = price >= HIGH_VALUE_THRESHOLD;
        
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
            address(this),
            isHighValue
        );
        
        // Registrar el escrow
        productEscrows[productId] = address(newEscrow);
        isEscrowContract[address(newEscrow)] = true;
        allProductIds.push(productId);
        allEscrowContracts.push(address(newEscrow));
        totalProductsCreated++;
        
        emit ProductEscrowCreated(
            productId,
            address(newEscrow),
            msg.sender,
            category,
            price,
            isHighValue
        );
        
        return address(newEscrow);
    }
    
    // Comprar producto con cálculo de comisión
    function buyProduct(uint256 productId) external nonReentrant whenNotPaused {
        address escrowAddress = productEscrows[productId];
        require(escrowAddress != address(0), "Product does not exist");
        
        ProductEscrow escrow = ProductEscrow(escrowAddress);
        uint256 price = escrow.price();
        
        // Calcular comisión
        uint256 fee = calculateFee(price, escrow.category(), escrow.isHighValue());
        
        // Verificar allowance (precio + comisión)
        require(
            campusCoin.allowance(msg.sender, address(escrow)) >= price,
            "Insufficient allowance for product"
        );
        
        // Si hay comisión, verificar allowance adicional
        if (fee > 0) {
            require(
                campusCoin.allowance(msg.sender, address(this)) >= fee,
                "Insufficient allowance for fee"
            );
        }
        
        // Ejecutar compra
        escrow.buy(msg.sender);
        
        // Cobrar comisión si aplica
        if (fee > 0) {
            require(
                campusCoin.transferFrom(msg.sender, feeRecipient, fee),
                "Fee transfer failed"
            );
            totalFeesCollected += fee;
            emit FeeCollected(productId, fee);
        }
        
        emit ProductSold(productId, msg.sender, price, fee);
    }
    
    // Confirmar entrega
    function confirmDelivery(uint256 productId) external nonReentrant whenNotPaused {
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
        require(bytes(reason).length > 0, "Reason required");
        
        ProductEscrow escrow = ProductEscrow(escrowAddress);
        escrow.emergencyCancel(reason);
    }
    
    // Calcular comisión basada en precio y categoría
    function calculateFee(uint256 price, ProductCategory category, bool isHighValue) public view returns (uint256) {
        uint256 baseFee = (price * platformFeePercent) / 10000;
        
        // Comisión adicional para productos de alto valor
        if (isHighValue) {
            baseFee += (price * 100) / 10000; // +1%
        }
        
        // Comisión adicional para categorías premium
        if (category == ProductCategory.ELECTRONICS) {
            baseFee += (price * PREMIUM_CATEGORY_FEE) / 10000; // +5%
        }
        
        return baseFee;
    }
    
    // Función de pausa de emergencia
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
    
    // Actualizar comisión de la plataforma
    function setPlatformFee(uint256 newFee) external onlyOwner {
        require(newFee <= MAX_FEE_PERCENT, "Fee too high");
        uint256 oldFee = platformFeePercent;
        platformFeePercent = newFee;
        emit PlatformFeeUpdated(oldFee, newFee);
    }
    
    // Actualizar destinatario de comisiones
    function setFeeRecipient(address newRecipient) external onlyOwner {
        require(newRecipient != address(0), "Invalid recipient");
        address oldRecipient = feeRecipient;
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(oldRecipient, newRecipient);
    }
    
    // Obtener estadísticas de la plataforma
    function getPlatformStats() external view returns (
        uint256 totalProducts,
        uint256 totalFees,
        uint256 averageFee,
        address currentFeeRecipient,
        uint256 currentFeePercent
    ) {
        return (
            totalProductsCreated,
            totalFeesCollected,
            totalProductsCreated > 0 ? totalFeesCollected / totalProductsCreated : 0,
            feeRecipient,
            platformFeePercent
        );
    }
    
    // Consultas optimizadas con paginación
    function getAllProductsPaginated(uint256 limit, uint256 offset) external view returns (
        uint256[] memory productIds,
        address[] memory escrowAddresses,
        address[] memory sellers,
        uint256[] memory prices,
        ProductCategory[] memory categories,
        bool[] memory isHighValue
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
        isHighValue = new bool[](resultLength);
        
        for (uint256 i = offset; i < end; i++) {
            uint256 productId = allProductIds[i];
            address escrowAddress = productEscrows[productId];
            ProductEscrow escrow = ProductEscrow(escrowAddress);
            
            uint256 index = i - offset;
            productIds[index] = productId;
            escrowAddresses[index] = escrowAddress;
            sellers[index] = escrow.seller();
            prices[index] = escrow.price();
            categories[index] = escrow.category();
            isHighValue[index] = escrow.isHighValue();
        }
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
