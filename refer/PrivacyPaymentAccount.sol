// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@account-abstraction/contracts/core/BaseAccount.sol";
import "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IPrivacyMerkleTree {
    function deposit(bytes32 commitment, uint256 amount) external;
    function withdraw(
        uint[2] calldata pA,
        uint[2][2] calldata pB,
        uint[2] calldata pC,
        uint[1] calldata pubSignals,
        bytes32 nullifier,
        address recipient,
        uint256 amount,
        uint256 chainId
    ) external;
}

contract PrivacyPaymentAccount is BaseAccount, ReentrancyGuard {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;
    
    // Validation constants for ERC-4337
    uint256 private constant SIG_VALIDATION_FAILED = 1;
    uint256 private constant SIG_VALIDATION_SUCCESS = 0;
    
    IEntryPoint private immutable _entryPoint;
    address public owner;
    
    // Privacy settings
    bool public privacyEnabled;
    address public privacyTreeContract;
    
    // Multi-chain routing
    struct ChainSplit {
        uint256 chainId;
        uint256 amount;
        address targetContract;
    }
    
    event OwnerInitialized(address indexed owner);
    event Executed(address indexed target, uint256 value, bytes data);
    event PrivacyPaymentInitiated(bytes32 commitment, uint256 amount);
    event MultiChainPaymentSplit(uint256 indexed paymentId, ChainSplit[] splits);
    event PrivacyToggled(bool enabled);
    
    constructor(IEntryPoint anEntryPoint) {
        _entryPoint = anEntryPoint;
        owner = address(0);
        privacyEnabled = true;
    }
    
    function initialize(address _owner, address _privacyTree) external {
        require(owner == address(0), "Already initialized");
        require(_owner != address(0), "Invalid owner");
        owner = _owner;
        privacyTreeContract = _privacyTree;
        emit OwnerInitialized(_owner);
    }
    
    function entryPoint() public view override returns (IEntryPoint) {
        return _entryPoint;
    }
    
    // Execute single transaction
    function execute(
        address target,
        uint256 value,
        bytes calldata data
    ) external onlyEntryPointOrOwner nonReentrant {
        _call(target, value, data);
        emit Executed(target, value, data);
    }
    
    // Execute batch transactions
    function executeBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata datas
    ) external onlyEntryPointOrOwner nonReentrant {
        require(targets.length == values.length && targets.length == datas.length, "Length mismatch");
        
        for (uint256 i = 0; i < targets.length; i++) {
            _call(targets[i], values[i], datas[i]);
        }
    }
    
    // Privacy-enabled payment with commitment
    function makePrivacyPayment(
        address token,
        uint256 amount,
        bytes32 commitment
    ) external onlyOwner nonReentrant {
        require(privacyEnabled, "Privacy disabled");
        require(privacyTreeContract != address(0), "Privacy tree not set");
        
        IERC20 paymentToken = IERC20(token);
        require(paymentToken.balanceOf(address(this)) >= amount, "Insufficient balance");
        
        paymentToken.approve(privacyTreeContract, amount);
        IPrivacyMerkleTree(privacyTreeContract).deposit(commitment, amount);
        
        emit PrivacyPaymentInitiated(commitment, amount);
    }
    
    // Multi-chain split payment
    function initiateMultiChainPayment(
        uint256 paymentId,
        ChainSplit[] calldata splits,
        address token,
        uint256 totalAmount
    ) external onlyOwner nonReentrant {
        require(splits.length > 0 && splits.length <= 5, "Invalid split count");
        
        uint256 splitSum = 0;
        for (uint256 i = 0; i < splits.length; i++) {
            splitSum += splits[i].amount;
        }
        require(splitSum == totalAmount, "Split sum mismatch");
        
        IERC20 paymentToken = IERC20(token);
        require(paymentToken.balanceOf(address(this)) >= totalAmount, "Insufficient balance");
        
        emit MultiChainPaymentSplit(paymentId, splits);
    }
    
    // Withdraw from privacy pool
    function withdrawFromPrivacyPool(
        uint[2] calldata pA,
        uint[2][2] calldata pB,
        uint[2] calldata pC,
        uint[1] calldata pubSignals,
        bytes32 nullifier,
        address recipient,
        uint256 amount
    ) external onlyOwner nonReentrant {
        require(privacyTreeContract != address(0), "Privacy tree not set");
        
        IPrivacyMerkleTree(privacyTreeContract).withdraw(
            pA, pB, pC, pubSignals, nullifier, recipient, amount, block.chainid
        );
    }
    
    function setPrivacyEnabled(bool _enabled) external onlyOwner {
        privacyEnabled = _enabled;
        emit PrivacyToggled(_enabled);
    }
    
    function setPrivacyTree(address _privacyTree) external onlyOwner {
        require(_privacyTree != address(0), "Invalid address");
        privacyTreeContract = _privacyTree;
    }
    
    function _validateSignature(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash
    ) internal view override returns (uint256 validationData) {
        bytes32 hash = userOpHash.toEthSignedMessageHash();
        address recovered = hash.recover(userOp.signature);
        
        if (recovered != owner) {
            return SIG_VALIDATION_FAILED;
        }
        return SIG_VALIDATION_SUCCESS;
    }
    
    function _call(address target, uint256 value, bytes calldata data) internal {
        (bool success, bytes memory result) = target.call{value: value}(data);
        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
    }
    
    function getDeposit() external view returns (uint256) {
        return _entryPoint.balanceOf(address(this));
    }
    
    function addDeposit() external payable {
        _entryPoint.depositTo{value: msg.value}(address(this));
    }
    
    function withdrawDepositTo(
        address payable withdrawAddress,
        uint256 amount
    ) external onlyOwner {
        _entryPoint.withdrawTo(withdrawAddress, amount);
    }
    
    function recoverERC20(address token, uint256 amount) external onlyOwner {
        IERC20(token).transfer(owner, amount);
    }
    
    modifier onlyEntryPointOrOwner() {
        require(
            msg.sender == address(_entryPoint) || msg.sender == owner,
            "Not authorized"
        );
        _;
    }
    
    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }
    
    receive() external payable {}
}
