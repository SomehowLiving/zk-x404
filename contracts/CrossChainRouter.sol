// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface ILayerZeroEndpoint {
    function send(
        uint16 dstChainId,
        bytes calldata destination,
        bytes calldata payload,
        address payable refundAddress,
        address zroPaymentAddress,
        bytes calldata adapterParams
    ) external payable;
}

contract CrossChainRouter is ReentrancyGuard, Ownable {
    
    // LayerZero endpoint for cross-chain messaging
    ILayerZeroEndpoint public immutable lzEndpoint;
    
    // Supported chains
    mapping(uint256 => bool) public supportedChains;
    mapping(uint256 => uint16) public chainIdToLzChainId; // EVM chainId -> LayerZero chainId
    mapping(uint256 => address) public chainIdToPrivacyTree; // chainId -> PrivacyMerkleTree address
    
    // Payment tracking
    struct PaymentSplit {
        uint256 paymentId;
        address sender;
        uint256[] chainIds;
        uint256[] amounts;
        bytes32[] commitments;
        uint256 timestamp;
        bool executed;
    }
    
    mapping(uint256 => PaymentSplit) public payments;
    uint256 public nextPaymentId;
    
    // Gas price oracle for optimization
    mapping(uint256 => uint256) public gasPrice; // chainId -> gas price in wei
    
    event ChainAdded(uint256 indexed chainId, uint16 lzChainId, address privacyTree);
    event ChainRemoved(uint256 indexed chainId);
    event PaymentSplitInitiated(
        uint256 indexed paymentId,
        address indexed sender,
        uint256[] chainIds,
        uint256[] amounts,
        uint256 totalAmount
    );
    event PaymentSplitExecuted(uint256 indexed paymentId);
    event GasPriceUpdated(uint256 indexed chainId, uint256 gasPrice);
    event CrossChainMessageSent(uint256 indexed paymentId, uint256 indexed dstChainId);
    
    constructor(address _lzEndpoint) Ownable(msg.sender) {
        require(_lzEndpoint != address(0), "Invalid endpoint");
        lzEndpoint = ILayerZeroEndpoint(_lzEndpoint);
        nextPaymentId = 1;
    }
    
    // Add supported chain
    function addChain(
        uint256 chainId,
        uint16 lzChainId,
        address privacyTree
    ) external onlyOwner {
        require(chainId > 0, "Invalid chainId");
        require(privacyTree != address(0), "Invalid privacy tree");
        
        supportedChains[chainId] = true;
        chainIdToLzChainId[chainId] = lzChainId;
        chainIdToPrivacyTree[chainId] = privacyTree;
        
        emit ChainAdded(chainId, lzChainId, privacyTree);
    }
    
    // Remove chain support
    function removeChain(uint256 chainId) external onlyOwner {
        supportedChains[chainId] = false;
        emit ChainRemoved(chainId);
    }
    
    // Update gas price for a chain (oracle feeds this)
    function updateGasPrice(uint256 chainId, uint256 _gasPrice) external onlyOwner {
        gasPrice[chainId] = _gasPrice;
        emit GasPriceUpdated(chainId, _gasPrice);
    }
    
    // Calculate optimal split based on gas prices
    function calculateOptimalSplit(
        uint256 totalAmount,
        uint256[] memory chainIds
    ) public view returns (uint256[] memory amounts) {
        require(chainIds.length > 0 && chainIds.length <= 5, "Invalid chain count");
        
        amounts = new uint256[](chainIds.length);
        
        // Calculate total gas cost across chains
        uint256 totalGasCost = 0;
        for (uint256 i = 0; i < chainIds.length; i++) {
            require(supportedChains[chainIds[i]], "Unsupported chain");
            totalGasCost += gasPrice[chainIds[i]];
        }
        
        if (totalGasCost == 0) {
            // Equal split if no gas data
            uint256 equalAmount = totalAmount / chainIds.length;
            for (uint256 i = 0; i < chainIds.length; i++) {
                amounts[i] = equalAmount;
            }
            return amounts;
        }
        
        // Inverse proportion: cheaper chains get more volume
        for (uint256 i = 0; i < chainIds.length; i++) {
            uint256 chainWeight = totalGasCost - gasPrice[chainIds[i]];
            amounts[i] = (totalAmount * chainWeight) / (totalGasCost * (chainIds.length - 1));
        }
        
        return amounts;
    }
    
    // Initiate multi-chain payment split
    function initiatePaymentSplit(
        uint256[] calldata chainIds,
        uint256[] calldata amounts,
        bytes32[] calldata commitments,
        address token
    ) external nonReentrant returns (uint256 paymentId) {
        require(chainIds.length == amounts.length, "Length mismatch");
        require(chainIds.length == commitments.length, "Length mismatch");
        require(chainIds.length > 0 && chainIds.length <= 5, "Invalid split count");
        
        // Validate all chains are supported
        uint256 totalAmount = 0;
        for (uint256 i = 0; i < chainIds.length; i++) {
            require(supportedChains[chainIds[i]], "Unsupported chain");
            require(amounts[i] > 0, "Invalid amount");
            totalAmount += amounts[i];
        }
        
        // Transfer tokens from sender
        IERC20 paymentToken = IERC20(token);
        require(
            paymentToken.transferFrom(msg.sender, address(this), totalAmount),
            "Transfer failed"
        );
        
        // Create payment split record
        paymentId = nextPaymentId++;
        payments[paymentId] = PaymentSplit({
            paymentId: paymentId,
            sender: msg.sender,
            chainIds: chainIds,
            amounts: amounts,
            commitments: commitments,
            timestamp: block.timestamp,
            executed: false
        });
        
        emit PaymentSplitInitiated(paymentId, msg.sender, chainIds, amounts, totalAmount);
        
        return paymentId;
    }
    
    // Execute cross-chain payment (can be called by relayer or sender)
    function executePaymentSplit(
        uint256 paymentId,
        address token
    ) external payable nonReentrant {
        PaymentSplit storage payment = payments[paymentId];
        require(payment.paymentId == paymentId, "Invalid payment");
        require(!payment.executed, "Already executed");
        require(
            msg.sender == payment.sender || msg.sender == owner(),
            "Not authorized"
        );
        
        // Mark as executed first (reentrancy protection)
        payment.executed = true;
        
        IERC20 paymentToken = IERC20(token);
        
        // Process each chain split
        for (uint256 i = 0; i < payment.chainIds.length; i++) {
            uint256 dstChainId = payment.chainIds[i];
            uint256 amount = payment.amounts[i];
            bytes32 commitment = payment.commitments[i];
            
            if (dstChainId == block.chainid) {
                // Local deposit
                address privacyTree = chainIdToPrivacyTree[dstChainId];
                require(privacyTree != address(0), "Privacy tree not configured");
                
                paymentToken.approve(privacyTree, amount);
                // Call deposit on privacy tree
                (bool success, ) = privacyTree.call(
                    abi.encodeWithSignature("deposit(bytes32,uint256)", commitment, amount)
                );
                require(success, "Local deposit failed");
            } else {
                // Cross-chain message via LayerZero
                uint16 lzDstChainId = chainIdToLzChainId[dstChainId];
                address dstPrivacyTree = chainIdToPrivacyTree[dstChainId];
                require(dstPrivacyTree != address(0), "Dst privacy tree not configured");
                
                // Encode cross-chain message
                bytes memory payload = abi.encode(commitment, amount, token);
                
                // Send via LayerZero (requires native gas)
                lzEndpoint.send{value: msg.value / payment.chainIds.length}(
                    lzDstChainId,
                    abi.encodePacked(dstPrivacyTree, address(this)),
                    payload,
                    payable(msg.sender),
                    address(0),
                    ""
                );
                
                emit CrossChainMessageSent(paymentId, dstChainId);
            }
        }
        
        emit PaymentSplitExecuted(paymentId);
    }
    
    // LayerZero receive function (called on destination chain)
    function lzReceive(
        uint16 srcChainId,
        bytes memory srcAddress,
        uint64 nonce,
        bytes memory payload
    ) external {
        require(msg.sender == address(lzEndpoint), "Only endpoint");
        
        // Decode payload
        (bytes32 commitment, uint256 amount, address token) = abi.decode(
            payload,
            (bytes32, uint256, address)
        );
        
        // Deposit into local privacy tree
        address privacyTree = chainIdToPrivacyTree[block.chainid];
        require(privacyTree != address(0), "Privacy tree not configured");
        
        IERC20(token).approve(privacyTree, amount);
        (bool success, ) = privacyTree.call(
            abi.encodeWithSignature("deposit(bytes32,uint256)", commitment, amount)
        );
        require(success, "Cross-chain deposit failed");
    }
    
    // View functions
    function getPayment(uint256 paymentId) external view returns (PaymentSplit memory) {
        return payments[paymentId];
    }
    
    function getSupportedChains() external view returns (uint256[] memory) {
        // In production, maintain a list of chain IDs
        // For now, return empty array (implement based on needs)
        return new uint256[](0);
    }
    
    // Emergency token recovery
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        IERC20(token).transfer(owner(), amount);
    }
}