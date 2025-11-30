//PrivacyMerkleTree.sol

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IVerifier {
    function verifyProof(
        uint[2] calldata pA,
        uint[2][2] calldata pB,
        uint[2] calldata pC,
        uint[1] calldata pubSignals
    ) external view returns (bool);
}

contract PrivacyMerkleTree is ReentrancyGuard, Ownable {
    uint256 public constant TREE_DEPTH = 20;
    uint256 public constant MAX_LEAVES = 2**TREE_DEPTH;
    uint256 public constant ZERO_VALUE = uint256(keccak256("crossx402.zero")) % 21888242871839275222246405745257275088548364400416034343698204186575808495617;
    
    IERC20 public immutable usdc;
    IVerifier public verifier;
    
    // Merkle tree storage - optimized with levels
    mapping(uint256 => bytes32) public commitments; // leaf index -> commitment
    mapping(uint256 => mapping(uint256 => bytes32)) public tree; // level -> index -> hash
    uint256 public nextLeafIndex;
    
    // Nullifier prevention (double-spend protection)
    mapping(bytes32 => bool) public nullifiers;
    
    // Root history (last 100 roots for flexibility)
    bytes32[100] public rootHistory;
    uint256 public currentRootIndex;
    
    // Statistics
    uint256 public totalDeposited;
    uint256 public totalWithdrawn;
    uint256 public depositCount;
    uint256 public withdrawCount;
    
    // Fee configuration
    uint256 public depositFee; // basis points (100 = 1%)
    uint256 public withdrawFee; // basis points
    address public feeRecipient;
    
    event Deposit(
        bytes32 indexed commitment,
        uint256 leafIndex,
        uint256 amount,
        uint256 timestamp
    );
    event Withdraw(
        address indexed recipient,
        uint256 amount,
        bytes32 nullifier,
        uint256 timestamp
    );
    event RootUpdated(bytes32 indexed oldRoot, bytes32 indexed newRoot, uint256 leafIndex);
    event VerifierUpdated(address indexed oldVerifier, address indexed newVerifier);
    event FeesUpdated(uint256 depositFee, uint256 withdrawFee);
    
    constructor(
        address _usdc,
        address _verifier,
        address _feeRecipient
    ) Ownable(msg.sender) {
        require(_usdc != address(0), "Invalid USDC");
        require(_verifier != address(0), "Invalid verifier");
        
        usdc = IERC20(_usdc);
        verifier = IVerifier(_verifier);
        feeRecipient = _feeRecipient;
        
        nextLeafIndex = 0;
        depositFee = 10; // 0.1%
        withdrawFee = 10; // 0.1%
        
        // Initialize first root
        bytes32 initialRoot = _calculateRoot(0);
        rootHistory[0] = initialRoot;
        currentRootIndex = 0;
    }
    
    // Deposit with commitment
    function deposit(bytes32 _commitment, uint256 _amount) external nonReentrant {
        require(_amount > 0, "Amount must be > 0");
        require(nextLeafIndex < MAX_LEAVES, "Tree is full");
        require(_commitment != bytes32(0), "Invalid commitment");
        
        // Calculate fee
        uint256 fee = (_amount * depositFee) / 10000;
        uint256 netAmount = _amount - fee;
        
        // Transfer USDC from depositor
        require(usdc.transferFrom(msg.sender, address(this), _amount), "Transfer failed");
        
        // Send fee to recipient
        if (fee > 0 && feeRecipient != address(0)) {
            require(usdc.transfer(feeRecipient, fee), "Fee transfer failed");
        }
        
        // Add commitment to tree
        uint256 leafIndex = nextLeafIndex;
        commitments[leafIndex] = _commitment;
        tree[0][leafIndex] = _commitment; // Store at level 0
        
        nextLeafIndex++;
        
        // Update Merkle root
        bytes32 oldRoot = getCurrentRoot();
        _updateTreePath(leafIndex);
        bytes32 newRoot = getCurrentRoot();
        
        // Store in root history (circular buffer)
        currentRootIndex = (currentRootIndex + 1) % 100;
        rootHistory[currentRootIndex] = newRoot;
        
        totalDeposited += netAmount;
        depositCount++;
        
        emit Deposit(_commitment, leafIndex, netAmount, block.timestamp);
        emit RootUpdated(oldRoot, newRoot, leafIndex);
    }
    
    // Withdraw with zero-knowledge proof
    function withdraw(
        uint[2] calldata pA,
        uint[2][2] calldata pB,
        uint[2] calldata pC,
        uint[1] calldata pubSignals,
        bytes32 _nullifier,
        address _recipient,
        uint256 _amount,
        uint256 _chainId
    ) external nonReentrant {
        require(!nullifiers[_nullifier], "Nullifier already spent");
        require(_recipient != address(0), "Invalid recipient");
        require(_amount > 0, "Amount must be > 0");
        require(block.chainid == _chainId, "Chain ID mismatch");
        
        // Verify the merkle root is in history
        bytes32 rootFromProof = bytes32(pubSignals[0]);
        require(_isKnownRoot(rootFromProof), "Unknown merkle root");
        
        // Calculate fee
        uint256 fee = (_amount * withdrawFee) / 10000;
        uint256 netAmount = _amount - fee;
        
        require(usdc.balanceOf(address(this)) >= _amount, "Insufficient pool");
        
        // Verify zero-knowledge proof
        require(verifier.verifyProof(pA, pB, pC, pubSignals), "Invalid proof");
        
        // Mark nullifier as spent (prevents double-spending)
        nullifiers[_nullifier] = true;
        
        // Transfer USDC to recipient
        require(usdc.transfer(_recipient, netAmount), "Transfer failed");
        
        // Send fee to recipient
        if (fee > 0 && feeRecipient != address(0)) {
            require(usdc.transfer(feeRecipient, fee), "Fee transfer failed");
        }
        
        totalWithdrawn += netAmount;
        withdrawCount++;
        
        emit Withdraw(_recipient, netAmount, _nullifier, block.timestamp);
    }
    
    // Update tree path after new leaf insertion
    function _updateTreePath(uint256 leafIndex) internal {
        uint256 currentIndex = leafIndex;
        bytes32 left;
        bytes32 right;
        
        for (uint256 level = 0; level < TREE_DEPTH; level++) {
            if (currentIndex % 2 == 0) {
                left = tree[level][currentIndex];
                right = _getOrDefaultZero(level, currentIndex + 1);
            } else {
                left = tree[level][currentIndex - 1];
                right = tree[level][currentIndex];
            }
            
            bytes32 parentHash = _hashPair(left, right);
            currentIndex = currentIndex / 2;
            tree[level + 1][currentIndex] = parentHash;
        }
    }
    
    // Calculate root from current state
    function _calculateRoot(uint256 leafCount) internal view returns (bytes32) {
        if (leafCount == 0) {
            return bytes32(ZERO_VALUE);
        }
        
        // Start from bottom level and compute upwards
        bytes32 currentHash = tree[0][0];
        for (uint256 level = 1; level <= TREE_DEPTH; level++) {
            currentHash = tree[level][0];
        }
        return currentHash;
    }
    
    // Get current Merkle root
    function getCurrentRoot() public view returns (bytes32) {
        return rootHistory[currentRootIndex];
    }
    
    // Check if root exists in history
    function _isKnownRoot(bytes32 root) internal view returns (bool) {
        if (root == bytes32(0)) return false;
        
        for (uint256 i = 0; i < 100; i++) {
            if (rootHistory[i] == root) return true;
        }
        return false;
    }
    
    // Hash pair helper (Poseidon in production, Keccak for simplicity)
    function _hashPair(bytes32 left, bytes32 right) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(left, right));
    }
    
    // Get value or default zero
    function _getOrDefaultZero(uint256 level, uint256 index) internal view returns (bytes32) {
        bytes32 value = tree[level][index];
        return value == bytes32(0) ? bytes32(ZERO_VALUE) : value;
    }
    
    // Admin functions
    function updateVerifier(address _newVerifier) external onlyOwner {
        require(_newVerifier != address(0), "Invalid verifier");
        address oldVerifier = address(verifier);
        verifier = IVerifier(_newVerifier);
        emit VerifierUpdated(oldVerifier, _newVerifier);
    }
    
    function updateFees(uint256 _depositFee, uint256 _withdrawFee) external onlyOwner {
        require(_depositFee <= 1000, "Fee too high"); // Max 10%
        require(_withdrawFee <= 1000, "Fee too high");
        depositFee = _depositFee;
        withdrawFee = _withdrawFee;
        emit FeesUpdated(_depositFee, _withdrawFee);
    }
    
    function updateFeeRecipient(address _newRecipient) external onlyOwner {
        require(_newRecipient != address(0), "Invalid recipient");
        feeRecipient = _newRecipient;
    }
    
    // View functions
    function getBalance() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }
    
    function getTreeState() external view returns (
        uint256 leaves,
        bytes32 root,
        uint256 deposited,
        uint256 withdrawn
    ) {
        return (nextLeafIndex, getCurrentRoot(), totalDeposited, totalWithdrawn);
    }
    
    function isNullifierSpent(bytes32 _nullifier) external view returns (bool) {
        return nullifiers[_nullifier];
    }
    
    function getRootHistory() external view returns (bytes32[100] memory) {
        return rootHistory;
    }
}