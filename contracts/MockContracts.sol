// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockERC20
 * @notice Mock USDC token for testing
 */
contract MockERC20 is ERC20 {
    uint8 private _decimals;
    
    constructor(
        string memory name,
        string memory symbol,
        uint8 decimals_
    ) ERC20(name, symbol) {
        _decimals = decimals_;
    }
    
    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
    
    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/**
 * @title MockVerifier
 * @notice Mock ZK proof verifier that always returns true (FOR TESTING ONLY)
 * @dev In production, use actual snark verifier from circom
 */
contract MockVerifier {
    function verifyProof(
        uint[2] calldata, // pA
        uint[2][2] calldata, // pB
        uint[2] calldata, // pC
        uint[1] calldata  // pubSignals
    ) external pure returns (bool) {
        // WARNING: Always returns true - only for testing!
        // Replace with actual verifier in production
        return true;
    }
}

/**
 * @title MockLZEndpoint
 * @notice Mock LayerZero endpoint for testing
 */
contract MockLZEndpoint {
    event MessageSent(
        uint16 indexed dstChainId,
        bytes destination,
        bytes payload
    );
    
    function send(
        uint16 dstChainId,
        bytes calldata destination,
        bytes calldata payload,
        address payable, // refundAddress
        address, // zroPaymentAddress
        bytes calldata // adapterParams
    ) external payable {
        emit MessageSent(dstChainId, destination, payload);
        
        // In real testing, you'd trigger lzReceive on destination
        // For now, just emit event
    }
    
    function estimateFees(
        uint16, // dstChainId
        address, // userApplication
        bytes calldata, // payload
        bool, // payInZRO
        bytes calldata // adapterParams
    ) external pure returns (uint256 nativeFee, uint256 zroFee) {
        return (0.01 ether, 0); // Mock fee
    }
}