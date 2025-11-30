// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@account-abstraction/contracts/core/BasePaymaster.sol";
import "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract PrivacyPaymaster is BasePaymaster {
    using ECDSA for bytes32;
    
    // ERC-4337 validation constants
    uint256 internal constant SIG_VALIDATION_FAILED = 1;
    uint256 internal constant SIG_VALIDATION_SUCCESS = 0;
    
    // Account whitelist
    mapping(address => bool) public approvedAccounts;
    mapping(address => uint256) public accountBalances;
    
    // Token support
    IERC20 public immutable usdc;
    uint256 public usdcToEthRate; // 18 decimals
    
    // Gas configuration
    uint256 public maxGasPrice;
    uint256 public maxGasLimit;
    
    // Statistics
    uint256 public totalSponsored;
    uint256 public operationCount;
    
    // Store contract deployer
    address private immutable deployer;
    
    event PaymasterDeposited(address indexed sender, uint256 amount);
    event PaymasterWithdrawn(address indexed to, uint256 amount);
    event AccountApproved(address indexed account, bool approved);
    event AccountFunded(address indexed account, uint256 amount);
    event GasSponsored(address indexed account, uint256 actualGasCost);
    event RateUpdated(uint256 newRate);
    event MaxGasConfigUpdated(uint256 maxGasPrice, uint256 maxGasLimit);
    
    constructor(
        IEntryPoint _entryPoint,
        address _usdc
    ) BasePaymaster(_entryPoint) {
        require(_usdc != address(0), "Invalid USDC");
        deployer = msg.sender;
        usdc = IERC20(_usdc);
        usdcToEthRate = 2500 * 1e18; // 1 ETH = 2500 USDC
        maxGasPrice = 100 gwei;
        maxGasLimit = 1000000;
    }
    
    function setAccountApproval(address account, bool approved) external onlyDeployer {
        require(account != address(0), "Invalid account");
        approvedAccounts[account] = approved;
        emit AccountApproved(account, approved);
    }
    
    function batchApproveAccounts(address[] calldata accounts) external onlyDeployer {
        for (uint256 i = 0; i < accounts.length; i++) {
            approvedAccounts[accounts[i]] = true;
            emit AccountApproved(accounts[i], true);
        }
    }
    
    function fundAccount(address account, uint256 usdcAmount) external {
        require(approvedAccounts[account], "Account not approved");
        require(usdcAmount > 0, "Invalid amount");
        
        require(usdc.transferFrom(msg.sender, address(this), usdcAmount), "Transfer failed");
        
        uint256 ethEquivalent = (usdcAmount * 1e18) / usdcToEthRate;
        accountBalances[account] += ethEquivalent;
        
        emit AccountFunded(account, ethEquivalent);
    }
    
    function _validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 /*userOpHash*/,
        uint256 requiredPreFund
    ) internal override returns (bytes memory context, uint256 validationData) {
        require(approvedAccounts[userOp.sender], "Account not approved");
        
        // Extract gas price from packed data
        uint256 maxFeePerGas = uint128(bytes16(userOp.accountGasLimits));
        require(maxFeePerGas <= maxGasPrice, "Gas price too high");
        
        if (accountBalances[userOp.sender] < requiredPreFund) {
            return ("", SIG_VALIDATION_FAILED);
        }
        
        accountBalances[userOp.sender] -= requiredPreFund;
        
        context = abi.encode(userOp.sender, requiredPreFund);
        validationData = SIG_VALIDATION_SUCCESS;
        
        return (context, validationData);
    }
    
    function _postOp(
        PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 /*actualUserOpFeePerGas*/
    ) internal override {
        (address account, uint256 preCharged) = abi.decode(context, (address, uint256));
        
        if (mode == PostOpMode.opSucceeded || mode == PostOpMode.opReverted) {
            uint256 refund = preCharged > actualGasCost ? preCharged - actualGasCost : 0;
            if (refund > 0) {
                accountBalances[account] += refund;
            }
            
            totalSponsored += actualGasCost;
            operationCount++;
            
            emit GasSponsored(account, actualGasCost);
        }
    }
    
    function updateUsdcRate(uint256 newRate) external onlyDeployer {
        require(newRate > 0, "Invalid rate");
        usdcToEthRate = newRate;
        emit RateUpdated(newRate);
    }
    
    function updateGasConfig(uint256 _maxGasPrice, uint256 _maxGasLimit) external onlyDeployer {
        require(_maxGasPrice > 0 && _maxGasLimit > 0, "Invalid config");
        maxGasPrice = _maxGasPrice;
        maxGasLimit = _maxGasLimit;
        emit MaxGasConfigUpdated(_maxGasPrice, _maxGasLimit);
    }
    
    // Renamed to avoid conflict with BasePaymaster.deposit()
    function addDeposit() external payable onlyDeployer {
        entryPoint.depositTo{value: msg.value}(address(this));
        emit PaymasterDeposited(msg.sender, msg.value);
    }
    
    function withdrawPaymaster(address payable to, uint256 amount) external onlyDeployer {
        entryPoint.withdrawTo(to, amount);
        emit PaymasterWithdrawn(to, amount);
    }
    
    function withdrawUSDC(address to, uint256 amount) external onlyDeployer {
        require(usdc.transfer(to, amount), "Transfer failed");
    }
    
    function getAccountBalance(address account) external view returns (uint256) {
        return accountBalances[account];
    }
    
    function getPaymasterBalance() external view returns (uint256) {
        return entryPoint.balanceOf(address(this));
    }
    
    function getStats() external view returns (uint256 sponsored, uint256 operations) {
        return (totalSponsored, operationCount);
    }
    
    // Custom modifier using deployer instead of Ownable
    modifier onlyDeployer() {
        require(msg.sender == deployer, "Only deployer");
        _;
    }
}