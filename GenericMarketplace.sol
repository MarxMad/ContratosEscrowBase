// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./CUToken.sol";

contract GenericMarketplace is ERC721URIStorage, Ownable, ReentrancyGuard {
    using Counters for Counters.Counter;
    Counters.Counter private _tokenIds;

    CampusCoin public campusCoin;
    
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
        campusCoin = CampusCoin(_campusCoin);
    }

    function listProduct(
        string memory tokenURI,
        string memory productName,
        string memory productDescription,
        uint256 price,
        ProductCategory category,
        uint256 deliveryTimeHours
    ) external returns (uint256) {
        require(price > 0, "Price must be greater than 0");
        require(deliveryTimeHours > 0, "Delivery time must be specified");
        require(bytes(productName).length > 0, "Product name required");
        
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

    function buy(uint256 tokenId) external nonReentrant {
        Product storage product = products[tokenId];
        require(!product.sold, "Product already sold");
        require(ownerOf(tokenId) == product.seller, "Seller no longer owns the product");
        require(msg.sender != product.seller, "Cannot buy your own product");
        
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

    function confirmDelivery(uint256 tokenId) external nonReentrant {
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
}
