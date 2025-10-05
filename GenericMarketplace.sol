// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "./CUToken.sol";

contract GenericMarketplace is ERC721URIStorage, Ownable, ReentrancyGuard, Pausable {
    using Counters for Counters.Counter;
    Counters.Counter private _tokenIds;

    CampusCoin public campusCoin;
    
    // Límites de seguridad
    uint256 public constant MAX_PRICE = 1000000 * 10**18; // 1M tokens máximo
    uint256 public constant MAX_DELIVERY_TIME = 30 * 24; // 30 días máximo
    uint256 public constant MIN_DELIVERY_TIME = 1; // 1 hora mínimo
    uint256 public constant MAX_STRING_LENGTH = 1000; // 1000 caracteres máximo
    
    // Categorías de productos
    enum ProductCategory {
        BOOKS,
        ELECTRONICS,
        CLOTHING,
        SPORTS,
        HOME,
        OTHER
    }

    struct Product {
        address seller;
        uint256 price;
        bool sold;
        bool confirmed;
        address buyer;
        ProductCategory category;
        string productName;
        string productDescription;
        uint256 deliveryTimeHours;
        uint256 purchaseTime;
        uint256 deliveryDeadline;
    }

    mapping(uint256 => Product) public products;
    uint256[] public allTokenIds;

    event ProductListed(uint256 indexed tokenId, address indexed seller, uint256 price, ProductCategory category);
    event ProductPurchased(uint256 indexed tokenId, address indexed buyer, uint256 price);
    event DeliveryConfirmed(uint256 indexed tokenId, address indexed buyer);
    event ProductCancelled(uint256 indexed tokenId, string reason);
    event RefundIssued(uint256 indexed tokenId, address indexed buyer, uint256 amount);

    constructor(address _campusCoin) ERC721("CampusMarketplace", "CMP") Ownable(msg.sender) {
        require(_campusCoin != address(0), "Invalid token address");
        campusCoin = CampusCoin(_campusCoin);
    }

    function listProduct(
        string memory tokenURI,
        string memory productName,
        string memory productDescription,
        uint256 price,
        ProductCategory category,
        uint256 deliveryTimeHours
    ) external whenNotPaused returns (uint256) {
        // Validaciones de entrada mejoradas
        require(bytes(productName).length > 0, "Product name required");
        require(bytes(productName).length <= MAX_STRING_LENGTH, "Product name too long");
        require(bytes(productDescription).length <= MAX_STRING_LENGTH, "Description too long");
        require(bytes(tokenURI).length <= MAX_STRING_LENGTH, "Token URI too long");
        require(price > 0, "Price must be greater than 0");
        require(price <= MAX_PRICE, "Price too high");
        require(deliveryTimeHours >= MIN_DELIVERY_TIME, "Delivery time too short");
        require(deliveryTimeHours <= MAX_DELIVERY_TIME, "Delivery time too long");
        
        _tokenIds.increment();
        uint256 newTokenId = _tokenIds.current();
        _mint(msg.sender, newTokenId);
        _setTokenURI(newTokenId, tokenURI);
        
        products[newTokenId] = Product({
            seller: msg.sender,
            price: price,
            sold: false,
            confirmed: false,
            buyer: address(0),
            category: category,
            productName: productName,
            productDescription: productDescription,
            deliveryTimeHours: deliveryTimeHours,
            purchaseTime: 0,
            deliveryDeadline: 0
        });
        
        allTokenIds.push(newTokenId);
        emit ProductListed(newTokenId, msg.sender, price, category);
        return newTokenId;
    }

    function buy(uint256 tokenId) external nonReentrant whenNotPaused {
        Product storage product = products[tokenId];
        require(!product.sold, "Product already sold");
        require(ownerOf(tokenId) == product.seller, "Seller no longer owns the product");
        require(msg.sender != product.seller, "Cannot buy your own product");
        
        // Verificar allowance antes de transferir
        require(
            campusCoin.allowance(msg.sender, address(this)) >= product.price,
            "Insufficient allowance"
        );
        
        require(
            campusCoin.transferFrom(msg.sender, address(this), product.price),
            "Transfer failed"
        );
        
        product.buyer = msg.sender;
        product.sold = true;
        product.purchaseTime = block.timestamp;
        product.deliveryDeadline = block.timestamp + (product.deliveryTimeHours * 1 hours);
        
        emit ProductPurchased(tokenId, msg.sender, product.price);
    }

    function confirmDelivery(uint256 tokenId) external nonReentrant whenNotPaused {
        Product storage product = products[tokenId];
        require(product.sold, "Product not sold");
        require(msg.sender == product.buyer, "Only buyer can confirm");
        require(!product.confirmed, "Already confirmed");

        product.confirmed = true;
        _transfer(product.seller, product.buyer, tokenId);
        require(
            campusCoin.transfer(product.seller, product.price),
            "Transfer to seller failed"
        );
        
        emit DeliveryConfirmed(tokenId, msg.sender);
    }
    
    // Nueva función: Cancelar transacción
    function cancelTransaction(uint256 tokenId, string memory reason) external nonReentrant {
        Product storage product = products[tokenId];
        require(product.sold, "Product not sold");
        require(!product.confirmed, "Product already delivered");
        require(bytes(reason).length > 0, "Reason required");
        require(
            msg.sender == product.buyer || msg.sender == product.seller || msg.sender == owner(),
            "Not authorized to cancel"
        );
        
        // Reembolsar al comprador
        require(
            campusCoin.transfer(product.buyer, product.price),
            "Refund failed"
        );
        
        emit RefundIssued(tokenId, product.buyer, product.price);
        emit ProductCancelled(tokenId, reason);
    }
    
    // Nueva función: Reembolso por timeout
    function requestRefund(uint256 tokenId) external nonReentrant {
        Product storage product = products[tokenId];
        require(product.sold, "Product not sold");
        require(!product.confirmed, "Product already delivered");
        require(block.timestamp > product.deliveryDeadline, "Delivery deadline not passed");
        require(msg.sender == product.buyer, "Only buyer can request refund");
        
        require(
            campusCoin.transfer(product.buyer, product.price),
            "Refund failed"
        );
        
        emit RefundIssued(tokenId, product.buyer, product.price);
        emit ProductCancelled(tokenId, "Delivery timeout");
    }

    // Funciones de consulta mejoradas
    function getAllProducts() external view returns (
        uint256[] memory tokenIds,
        address[] memory sellers,
        uint256[] memory prices,
        bool[] memory soldFlags,
        bool[] memory confirmedFlags,
        address[] memory buyers,
        ProductCategory[] memory categories,
        string[] memory productNames
    ) {
        uint256 length = allTokenIds.length;
        tokenIds = new uint256[](length);
        sellers = new address[](length);
        prices = new uint256[](length);
        soldFlags = new bool[](length);
        confirmedFlags = new bool[](length);
        buyers = new address[](length);
        categories = new ProductCategory[](length);
        productNames = new string[](length);

        for (uint256 i = 0; i < length; i++) {
            uint256 tokenId = allTokenIds[i];
            Product storage product = products[tokenId];
            tokenIds[i] = tokenId;
            sellers[i] = product.seller;
            prices[i] = product.price;
            soldFlags[i] = product.sold;
            confirmedFlags[i] = product.confirmed;
            buyers[i] = product.buyer;
            categories[i] = product.category;
            productNames[i] = product.productName;
        }
    }

    function getProductsByCategory(ProductCategory category) external view returns (uint256[] memory) {
        uint256 count = 0;
        for (uint256 i = 0; i < allTokenIds.length; i++) {
            if (products[allTokenIds[i]].category == category) {
                count++;
            }
        }

        uint256[] memory categoryProducts = new uint256[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < allTokenIds.length; i++) {
            if (products[allTokenIds[i]].category == category) {
                categoryProducts[index] = allTokenIds[i];
                index++;
            }
        }
        return categoryProducts;
    }

    function getMyProducts(address user) external view returns (uint256[] memory) {
        uint256 count = 0;
        for (uint256 i = 0; i < allTokenIds.length; i++) {
            if (products[allTokenIds[i]].seller == user) {
                count++;
            }
        }

        uint256[] memory myProducts = new uint256[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < allTokenIds.length; i++) {
            if (products[allTokenIds[i]].seller == user) {
                myProducts[index] = allTokenIds[i];
                index++;
            }
        }
        return myProducts;
    }

    function getMyPurchases(address user) external view returns (uint256[] memory) {
        uint256 count = 0;
        for (uint256 i = 0; i < allTokenIds.length; i++) {
            if (products[allTokenIds[i]].buyer == user) {
                count++;
            }
        }

        uint256[] memory myPurchases = new uint256[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < allTokenIds.length; i++) {
            if (products[allTokenIds[i]].buyer == user) {
                myPurchases[index] = allTokenIds[i];
                index++;
            }
        }
        return myPurchases;
    }
    
    function getProductDetails(uint256 tokenId) external view returns (
        string memory productName,
        string memory productDescription,
        uint256 price,
        ProductCategory category,
        address seller,
        address buyer,
        bool sold,
        bool confirmed,
        uint256 deliveryTimeHours,
        uint256 purchaseTime,
        uint256 deliveryDeadline
    ) {
        Product storage product = products[tokenId];
        return (
            product.productName,
            product.productDescription,
            product.price,
            product.category,
            product.seller,
            product.buyer,
            product.sold,
            product.confirmed,
            product.deliveryTimeHours,
            product.purchaseTime,
            product.deliveryDeadline
        );
    }
    
    function isExpired(uint256 tokenId) external view returns (bool) {
        Product storage product = products[tokenId];
        return block.timestamp > product.deliveryDeadline && product.sold && !product.confirmed;
    }
    
    // ===== FUNCIONES ADICIONALES PARA FRONTEND =====
    
    // Obtener estadísticas del marketplace
    function getMarketplaceStats() external view returns (
        uint256 totalProducts,
        uint256 totalSold,
        uint256 totalConfirmed,
        uint256 totalActive
    ) {
        totalProducts = allTokenIds.length;
        uint256 sold = 0;
        uint256 confirmed = 0;
        uint256 active = 0;
        
        for (uint256 i = 0; i < allTokenIds.length; i++) {
            Product storage product = products[allTokenIds[i]];
            if (product.sold) {
                sold++;
                if (product.confirmed) {
                    confirmed++;
                } else {
                    active++;
                }
            }
        }
        
        return (totalProducts, sold, confirmed, active);
    }
    
    // Obtener productos por estado (disponibles, vendidos, confirmados)
    function getProductsByStatus(bool sold, bool confirmed) external view returns (uint256[] memory) {
        uint256 count = 0;
        for (uint256 i = 0; i < allTokenIds.length; i++) {
            Product storage product = products[allTokenIds[i]];
            if (product.sold == sold && product.confirmed == confirmed) {
                count++;
            }
        }
        
        uint256[] memory filteredProducts = new uint256[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < allTokenIds.length; i++) {
            Product storage product = products[allTokenIds[i]];
            if (product.sold == sold && product.confirmed == confirmed) {
                filteredProducts[index] = allTokenIds[i];
                index++;
            }
        }
        return filteredProducts;
    }
    
    // Obtener historial completo de un usuario
    function getUserHistory(address user) external view returns (
        uint256[] memory listedProducts,
        uint256[] memory purchasedProducts,
        uint256[] memory soldProducts,
        uint256[] memory confirmedPurchases
    ) {
        uint256 listedCount = 0;
        uint256 purchasedCount = 0;
        uint256 soldCount = 0;
        uint256 confirmedCount = 0;
        
        // Contar productos
        for (uint256 i = 0; i < allTokenIds.length; i++) {
            Product storage product = products[allTokenIds[i]];
            if (product.seller == user) {
                listedCount++;
                if (product.sold) {
                    soldCount++;
                }
            }
            if (product.buyer == user) {
                purchasedCount++;
                if (product.confirmed) {
                    confirmedCount++;
                }
            }
        }
        
        // Crear arrays
        listedProducts = new uint256[](listedCount);
        purchasedProducts = new uint256[](purchasedCount);
        soldProducts = new uint256[](soldCount);
        confirmedPurchases = new uint256[](confirmedCount);
        
        uint256 listedIndex = 0;
        uint256 purchasedIndex = 0;
        uint256 soldIndex = 0;
        uint256 confirmedIndex = 0;
        
        // Llenar arrays
        for (uint256 i = 0; i < allTokenIds.length; i++) {
            Product storage product = products[allTokenIds[i]];
            if (product.seller == user) {
                listedProducts[listedIndex] = allTokenIds[i];
                listedIndex++;
                if (product.sold) {
                    soldProducts[soldIndex] = allTokenIds[i];
                    soldIndex++;
                }
            }
            if (product.buyer == user) {
                purchasedProducts[purchasedIndex] = allTokenIds[i];
                purchasedIndex++;
                if (product.confirmed) {
                    confirmedPurchases[confirmedIndex] = allTokenIds[i];
                    confirmedIndex++;
                }
            }
        }
    }
    
    // Obtener productos que están próximos a expirar
    function getExpiringProducts(uint256 hoursFromNow) external view returns (uint256[] memory) {
        uint256 deadline = block.timestamp + (hoursFromNow * 1 hours);
        uint256 count = 0;
        
        for (uint256 i = 0; i < allTokenIds.length; i++) {
            Product storage product = products[allTokenIds[i]];
            if (product.sold && !product.confirmed && product.deliveryDeadline <= deadline) {
                count++;
            }
        }
        
        uint256[] memory expiringProducts = new uint256[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < allTokenIds.length; i++) {
            Product storage product = products[allTokenIds[i]];
            if (product.sold && !product.confirmed && product.deliveryDeadline <= deadline) {
                expiringProducts[index] = allTokenIds[i];
                index++;
            }
        }
        return expiringProducts;
    }
    
    // Obtener tiempo restante para entrega
    function getTimeRemaining(uint256 tokenId) external view returns (uint256) {
        Product storage product = products[tokenId];
        if (block.timestamp >= product.deliveryDeadline) {
            return 0;
        }
        return product.deliveryDeadline - block.timestamp;
    }
    
    // Verificar si un usuario puede comprar un producto
    function canBuy(uint256 tokenId, address buyer) external view returns (bool, string memory) {
        Product storage product = products[tokenId];
        
        if (product.sold) {
            return (false, "Product already sold");
        }
        if (buyer == product.seller) {
            return (false, "Cannot buy your own product");
        }
        if (ownerOf(tokenId) != product.seller) {
            return (false, "Seller no longer owns the product");
        }
        
        return (true, "Can buy");
    }
    
    // Verificar si un usuario puede confirmar entrega
    function canConfirmDelivery(uint256 tokenId, address user) external view returns (bool, string memory) {
        Product storage product = products[tokenId];
        
        if (!product.sold) {
            return (false, "Product not sold");
        }
        if (user != product.buyer) {
            return (false, "Only buyer can confirm");
        }
        if (product.confirmed) {
            return (false, "Already confirmed");
        }
        
        return (true, "Can confirm");
    }
    
    // Obtener productos por rango de precio
    function getProductsByPriceRange(uint256 minPrice, uint256 maxPrice) external view returns (uint256[] memory) {
        uint256 count = 0;
        for (uint256 i = 0; i < allTokenIds.length; i++) {
            Product storage product = products[allTokenIds[i]];
            if (product.price >= minPrice && product.price <= maxPrice) {
                count++;
            }
        }
        
        uint256[] memory priceFilteredProducts = new uint256[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < allTokenIds.length; i++) {
            Product storage product = products[allTokenIds[i]];
            if (product.price >= minPrice && product.price <= maxPrice) {
                priceFilteredProducts[index] = allTokenIds[i];
                index++;
            }
        }
        return priceFilteredProducts;
    }
    
    // Obtener total de productos por categoría
    function getCategoryStats() external view returns (
        uint256 books,
        uint256 electronics,
        uint256 clothing,
        uint256 sports,
        uint256 home,
        uint256 other
    ) {
        for (uint256 i = 0; i < allTokenIds.length; i++) {
            Product storage product = products[allTokenIds[i]];
            if (product.category == ProductCategory.BOOKS) books++;
            else if (product.category == ProductCategory.ELECTRONICS) electronics++;
            else if (product.category == ProductCategory.CLOTHING) clothing++;
            else if (product.category == ProductCategory.SPORTS) sports++;
            else if (product.category == ProductCategory.HOME) home++;
            else if (product.category == ProductCategory.OTHER) other++;
        }
    }
    
    // Funciones de pausa de emergencia
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
    
    // Función de emergencia para recuperar tokens
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        require(token != address(0), "Invalid token address");
        require(amount > 0, "Amount must be greater than 0");
        
        if (token == address(campusCoin)) {
            require(campusCoin.transfer(owner(), amount), "Transfer failed");
        }
    }
    
    // Consultas optimizadas con paginación
    function getAllProductsPaginated(uint256 limit, uint256 offset) external view returns (
        uint256[] memory tokenIds,
        address[] memory sellers,
        uint256[] memory prices,
        bool[] memory soldFlags,
        bool[] memory confirmedFlags,
        address[] memory buyers,
        ProductCategory[] memory categories,
        string[] memory productNames
    ) {
        require(limit > 0 && limit <= 100, "Invalid limit");
        require(offset < allTokenIds.length, "Invalid offset");
        
        uint256 length = allTokenIds.length;
        uint256 end = offset + limit;
        if (end > length) end = length;
        
        uint256 resultLength = end - offset;
        tokenIds = new uint256[](resultLength);
        sellers = new address[](resultLength);
        prices = new uint256[](resultLength);
        soldFlags = new bool[](resultLength);
        confirmedFlags = new bool[](resultLength);
        buyers = new address[](resultLength);
        categories = new ProductCategory[](resultLength);
        productNames = new string[](resultLength);

        for (uint256 i = offset; i < end; i++) {
            uint256 tokenId = allTokenIds[i];
            Product storage product = products[tokenId];
            uint256 index = i - offset;
            tokenIds[index] = tokenId;
            sellers[index] = product.seller;
            prices[index] = product.price;
            soldFlags[index] = product.sold;
            confirmedFlags[index] = product.confirmed;
            buyers[index] = product.buyer;
            categories[index] = product.category;
            productNames[index] = product.productName;
        }
    }
}
