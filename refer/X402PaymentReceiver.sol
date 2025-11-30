// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./CrossChainVerifier.sol";

/**
 * @title X402PaymentReceiver
 * @notice Merchant contract for receiving x402 payments with privacy
 * @dev Integrates with CrossX402 for privacy-enabled payments
 */
contract X402PaymentReceiver {
    CrossChainVerifier public immutable verifier;
    
    address public owner;
    uint256 public price; // Default price in wei
    
    // Payment records (minimal for privacy)
    mapping(bytes32 => PaymentRecord) public payments;
    mapping(address => uint256) public userAccessExpiry;
    
    struct PaymentRecord {
        uint256 timestamp;
        uint256 amount;
        bool isPrivate;
        uint256 accessDuration; // seconds of access granted
    }
    
    // Access control
    mapping(address => bool) public hasAccess;
    uint256 public defaultAccessDuration = 30 days;
    
    // Events
    event PaymentReceived(
        bytes32 indexed paymentId,
        uint256 amount,
        bool isPrivate,
        uint256 accessUntil
    );
    
    event AccessGranted(address indexed user, uint256 expiryTime);
    event AccessRevoked(address indexed user);
    event PriceUpdated(uint256 newPrice);
    
    // Errors
    error Unauthorized();
    error InvalidPayment();
    error InsufficientPayment();
    error AccessExpired();
    
    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }
    
    constructor(address _verifier, uint256 _price) {
        verifier = CrossChainVerifier(_verifier);
        owner = msg.sender;
        price = _price;
    }
    
    /**
     * @notice Process a privacy-enabled x402 payment
     * @param proof Zero-knowledge proof
     * @param publicInputs Public parameters
     * @return paymentId Unique payment identifier
     */
    function processPrivatePayment(
        CrossChainVerifier.PaymentProof calldata proof,
        CrossChainVerifier.PublicInputs calldata publicInputs
    ) external returns (bytes32 paymentId) {
        // Verify proof
        bool isValid = verifier.verifyPaymentProof(proof, publicInputs);
        if (!isValid) revert InvalidPayment();
        
        // Check amount (if not hidden)
        if (publicInputs.amount > 0 && publicInputs.amount < price) {
            revert InsufficientPayment();
        }
        
        // Generate payment ID
        paymentId = keccak256(abi.encodePacked(
            publicInputs.nullifier,
            block.timestamp,
            msg.sender
        ));
        
        // Record payment (minimal info for privacy)
        payments[paymentId] = PaymentRecord({
            timestamp: block.timestamp,
            amount: publicInputs.amount, // 0 if hidden
            isPrivate: true,
            accessDuration: defaultAccessDuration
        });
        
        // Grant access to the payer
        uint256 expiryTime = block.timestamp + defaultAccessDuration;
        userAccessExpiry[msg.sender] = expiryTime;
        hasAccess[msg.sender] = true;
        
        emit PaymentReceived(paymentId, publicInputs.amount, true, expiryTime);
        emit AccessGranted(msg.sender, expiryTime);
        
        return paymentId;
    }
    
    /**
     * @notice Process a standard (non-private) x402 payment
     * @dev Fallback for users without CrossX402 extension
     */
    function processStandardPayment() external payable returns (bytes32 paymentId) {
        if (msg.value < price) revert InsufficientPayment();
        
        paymentId = keccak256(abi.encodePacked(
            msg.sender,
            block.timestamp,
            msg.value
        ));
        
        payments[paymentId] = PaymentRecord({
            timestamp: block.timestamp,
            amount: msg.value,
            isPrivate: false,
            accessDuration: defaultAccessDuration
        });
        
        uint256 expiryTime = block.timestamp + defaultAccessDuration;
        userAccessExpiry[msg.sender] = expiryTime;
        hasAccess[msg.sender] = true;
        
        emit PaymentReceived(paymentId, msg.value, false, expiryTime);
        emit AccessGranted(msg.sender, expiryTime);
        
        return paymentId;
    }
    
    /**
     * @notice Check if user has valid access
     * @param user Address to check
     */
    function checkAccess(address user) external view returns (bool) {
        if (!hasAccess[user]) return false;
        if (userAccessExpiry[user] < block.timestamp) return false;
        return true;
    }
    
    /**
     * @notice Verify user has access (reverts if not)
     */
    function requireAccess(address user) external view {
        if (!hasAccess[user] || userAccessExpiry[user] < block.timestamp) {
            revert AccessExpired();
        }
    }
    
    /**
     * @notice Extend access for a user (owner only)
     */
    function extendAccess(address user, uint256 additionalTime) external onlyOwner {
        userAccessExpiry[user] += additionalTime;
        emit AccessGranted(user, userAccessExpiry[user]);
    }
    
    /**
     * @notice Revoke access for a user (owner only)
     */
    function revokeAccess(address user) external onlyOwner {
        hasAccess[user] = false;
        userAccessExpiry[user] = 0;
        emit AccessRevoked(user);
    }
    
    /**
     * @notice Update service price (owner only)
     */
    function setPrice(uint256 newPrice) external onlyOwner {
        price = newPrice;
        emit PriceUpdated(newPrice);
    }
    
    /**
     * @notice Update default access duration (owner only)
     */
    function setDefaultAccessDuration(uint256 duration) external onlyOwner {
        defaultAccessDuration = duration;
    }
    
    /**
     * @notice Withdraw collected funds (owner only)
     */
    function withdraw() external onlyOwner {
        uint256 balance = address(this).balance;
        (bool success, ) = owner.call{value: balance}("");
        require(success, "Transfer failed");
    }
    
    /**
     * @notice Get payment details
     */
    function getPayment(bytes32 paymentId) external view returns (
        uint256 timestamp,
        uint256 amount,
        bool isPrivate,
        uint256 accessDuration
    ) {
        PaymentRecord memory payment = payments[paymentId];
        return (
            payment.timestamp,
            payment.amount,
            payment.isPrivate,
            payment.accessDuration
        );
    }
    
    /**
     * @notice Get user's access expiry time
     */
    function getAccessExpiry(address user) external view returns (uint256) {
        return userAccessExpiry[user];
    }
    
    /**
     * @notice Get time remaining on user's access
     */
    function getTimeRemaining(address user) external view returns (uint256) {
        if (!hasAccess[user]) return 0;
        if (userAccessExpiry[user] <= block.timestamp) return 0;
        return userAccessExpiry[user] - block.timestamp;
    }
    
    // Receive ETH for standard payments
    receive() external payable {
        // Auto-process as standard payment
        this.processStandardPayment();
    }
}