// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/Create2.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IPrivacyPaymentAccount {
    function initialize(address owner, address privacyTree) external;
}

contract AccountFactory is Ownable {
    
    address public immutable accountImplementation;
    address public immutable entryPoint;
    address public privacyTreeContract;
    
    // Track deployed accounts
    mapping(address => address) public ownerToAccount;
    mapping(address => bool) public isAccount;
    address[] public allAccounts;
    
    event AccountCreated(
        address indexed owner,
        address indexed account,
        uint256 salt
    );
    event PrivacyTreeUpdated(address indexed oldTree, address indexed newTree);
    
    constructor(
        address _accountImplementation,
        address _entryPoint,
        address _privacyTree
    ) Ownable(msg.sender) {
        require(_accountImplementation != address(0), "Invalid implementation");
        require(_entryPoint != address(0), "Invalid entryPoint");
        
        accountImplementation = _accountImplementation;
        entryPoint = _entryPoint;
        privacyTreeContract = _privacyTree;
    }
    
    // Get counterfactual address (without deploying)
    function getAddress(address owner, uint256 salt) public view returns (address) {
        bytes32 bytecodeHash = keccak256(
            abi.encodePacked(
                type(AccountProxy).creationCode,
                abi.encode(accountImplementation, entryPoint)
            )
        );
        
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                _getSalt(owner, salt),
                bytecodeHash
            )
        );
        
        return address(uint160(uint256(hash)));
    }
    
    // Create account for owner
    function createAccount(
        address owner,
        uint256 salt
    ) external returns (address account) {
        require(owner != address(0), "Invalid owner");
        
        // Check if account already exists
        account = getAddress(owner, salt);
        if (isAccount[account]) {
            return account;
        }
        
        // Deploy using CREATE2
        bytes memory bytecode = abi.encodePacked(
            type(AccountProxy).creationCode,
            abi.encode(accountImplementation, entryPoint)
        );
        
        account = Create2.deploy(0, _getSalt(owner, salt), bytecode);
        
        // Initialize account
        IPrivacyPaymentAccount(account).initialize(owner, privacyTreeContract);
        
        // Track account
        ownerToAccount[owner] = account;
        isAccount[account] = true;
        allAccounts.push(account);
        
        emit AccountCreated(owner, account, salt);
        
        return account;
    }
    
    // Batch create accounts
    function batchCreateAccounts(
        address[] calldata owners,
        uint256[] calldata salts
    ) external returns (address[] memory accounts) {
        require(owners.length == salts.length, "Length mismatch");
        
        accounts = new address[](owners.length);
        for (uint256 i = 0; i < owners.length; i++) {
            accounts[i] = this.createAccount(owners[i], salts[i]);
        }
        
        return accounts;
    }
    
    // Update privacy tree contract
    function updatePrivacyTree(address _newPrivacyTree) external onlyOwner {
        require(_newPrivacyTree != address(0), "Invalid address");
        address oldTree = privacyTreeContract;
        privacyTreeContract = _newPrivacyTree;
        emit PrivacyTreeUpdated(oldTree, _newPrivacyTree);
    }
    
    // Get salt for CREATE2
    function _getSalt(address owner, uint256 salt) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(owner, salt));
    }
    
    // View functions
    function getAccountForOwner(address owner) external view returns (address) {
        return ownerToAccount[owner];
    }
    
    function getAllAccounts() external view returns (address[] memory) {
        return allAccounts;
    }
    
    function getAccountCount() external view returns (uint256) {
        return allAccounts.length;
    }
}

// Minimal proxy for account deployment
contract AccountProxy {
    address public immutable implementation;
    address public immutable entryPoint;
    
    constructor(address _implementation, address _entryPoint) {
        implementation = _implementation;
        entryPoint = _entryPoint;
    }
    
    fallback() external payable {
        address impl = implementation;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
    
    receive() external payable {}
}