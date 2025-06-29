// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IFlashLoanRecipient {
    function receiveFlashLoan(
        IERC20[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external;
}

interface IBalancerVault {
    function flashLoan(
        IFlashLoanRecipient recipient,
        IERC20[] memory tokens,
        uint256[] memory amounts,
        bytes memory userData
    ) external;
}

interface IWETH {
    function withdraw(uint256) external;
    function deposit() external payable;
}

contract FlashArbitrageBot is ReentrancyGuard, Ownable, IFlashLoanRecipient {
    using SafeERC20 for IERC20;
    
    address constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    
    enum ArbitrageType {
        SINGLE_HOP,     // A->B->A (2 swaps)
        TRIANGULAR,     // A->B->C->A (3 swaps) 
        MULTI_HOP,      // A->B->C->D->A (4+ swaps)
        SANDWICH,       // Front+back user tx
        CROSS_DEX,      // Same pair, different DEXes
        CUSTOM          // Custom swap sequence
    }
    
    struct SwapStep {
        address target;         // DEX router/contract address
        bytes callData;         // Encoded function call
        uint256 value;          // ETH value to send (for native swaps)
        bool requireSuccess;    // Whether to revert on failure
    }
    
    struct ArbitrageParams {
        ArbitrageType arbType;
        address[] tokens;           // Flashloan tokens
        uint256[] amounts;          // Flashloan amounts
        SwapStep[] swaps;           // Sequence of swaps to execute
        uint256 minProfit;          // Minimum profit threshold (in wei)
        address profitToken;        // Token to receive profit in
        address caller;             // Profit recipient
        uint256 deadline;           // Execution deadline
        bytes extraData;            // Additional data for complex strategies
    }
    
    mapping(address => bool) public authorized;
    mapping(address => bool) public trustedDEXes;
    
    uint256 public maxFlashLoanSize = 10000000e6; // 10M USDC max
    uint256 public minProfitThreshold = 1e6; // 1 USDC minimum
    bool public emergencyStop = false;
    
    event ArbitrageExecuted(
        ArbitrageType arbType,
        uint256 profit,
        address profitToken,
        address caller,
        uint256 gasUsed
    );
    
    event SwapExecuted(
        address indexed target,
        bool success,
        uint256 stepIndex
    );
    
    event ProfitExtracted(
        address indexed token,
        uint256 amount,
        address indexed recipient
    );
    
    modifier onlyAuth() {
        require(authorized[msg.sender] && !emergencyStop, "Unauthorized or emergency stop");
        _;
    }
    
    modifier validDeadline(uint256 deadline) {
        require(deadline >= block.timestamp, "Expired deadline");
        _;
    }
    
    constructor() Ownable(msg.sender) {
        authorized[msg.sender] = true;
        
        // Pre-approve common DEXes
        trustedDEXes[0x2626664c2603336E57B271c5C0b26F421741e481] = true; // Uniswap V3
        trustedDEXes[0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43] = true; // Aerodrome
        trustedDEXes[0x327Df1E6de05895d2ab08513aaDD9313Fe505d86] = true; // BaseSwap
    }
    
    // Single token flashloan arbitrage
    function executeSingle(
        ArbitrageType arbType,
        address token,
        uint256 amount,
        SwapStep[] calldata swaps,
        uint256 minProfit,
        uint256 deadline
    ) external onlyAuth nonReentrant validDeadline(deadline) {
        require(amount <= maxFlashLoanSize, "Amount exceeds limit");
        require(minProfit >= minProfitThreshold, "Profit below threshold");
        
        ArbitrageParams memory params = ArbitrageParams({
            arbType: arbType,
            tokens: new address[](1),
            amounts: new uint256[](1), 
            swaps: swaps,
            minProfit: minProfit,
            profitToken: token,
            caller: msg.sender,
            deadline: deadline,
            extraData: ""
        });
        
        params.tokens[0] = token;
        params.amounts[0] = amount;
        
        _executeFlashloan(params);
    }
    
    // Multi-token flashloan arbitrage  
    function executeMulti(
        ArbitrageType arbType,
        address[] calldata tokens,
        uint256[] calldata amounts,
        SwapStep[] calldata swaps,
        uint256 minProfit,
        address profitToken,
        uint256 deadline,
        bytes calldata extraData
    ) external onlyAuth nonReentrant validDeadline(deadline) {
        require(tokens.length == amounts.length, "Length mismatch");
        require(minProfit >= minProfitThreshold, "Profit below threshold");
        
        // Check flashloan limits
        for (uint i = 0; i < amounts.length; i++) {
            require(amounts[i] <= maxFlashLoanSize, "Amount exceeds limit");
        }
        
        ArbitrageParams memory params = ArbitrageParams({
            arbType: arbType,
            tokens: tokens,
            amounts: amounts,
            swaps: swaps,
            minProfit: minProfit,
            profitToken: profitToken,
            caller: msg.sender,
            deadline: deadline,
            extraData: extraData
        });
        
        _executeFlashloan(params);
    }
    
    // Advanced execution with custom routing
    function executeAdvanced(
        ArbitrageParams calldata params
    ) external onlyAuth nonReentrant validDeadline(params.deadline) {
        require(params.caller == msg.sender, "Invalid caller");
        require(params.minProfit >= minProfitThreshold, "Profit below threshold");
        
        _executeFlashloan(params);
    }
    
    function _executeFlashloan(ArbitrageParams memory params) private {
        IERC20[] memory tokens = new IERC20[](params.tokens.length);
        for (uint i = 0; i < params.tokens.length; i++) {
            tokens[i] = IERC20(params.tokens[i]);
        }
        
        bytes memory userData = abi.encode(params);
        
        IBalancerVault(BALANCER_VAULT).flashLoan(this, tokens, params.amounts, userData);
    }
    
    function receiveFlashLoan(
        IERC20[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external override {
        require(msg.sender == BALANCER_VAULT, "Invalid caller");
        
        uint256 gasStart = gasleft();
        ArbitrageParams memory params = abi.decode(userData, (ArbitrageParams));
        
        // Record initial balances for profit calculation
        uint256[] memory initialBalances = new uint256[](tokens.length);
        for (uint i = 0; i < tokens.length; i++) {
            initialBalances[i] = tokens[i].balanceOf(address(this));
        }
        
        // Execute arbitrage strategy
        _executeStrategy(params);
        
        // Calculate and validate profit
        uint256 profit = _calculateProfit(params, tokens, amounts, initialBalances, feeAmounts);
        require(profit >= params.minProfit, "Insufficient profit");
        
        // Repay flashloans (including fees)
        for (uint i = 0; i < tokens.length; i++) {
            uint256 repayAmount = amounts[i] + feeAmounts[i];
            tokens[i].safeTransfer(BALANCER_VAULT, repayAmount);
        }
        
        // Send profit to caller
        _sendProfit(params.profitToken, profit, params.caller);
        
        uint256 gasUsed = gasStart - gasleft();
        
        emit ArbitrageExecuted(
            params.arbType, 
            profit, 
            params.profitToken, 
            params.caller,
            gasUsed
        );
    }
    
    function _executeStrategy(ArbitrageParams memory params) private {
        if (params.arbType == ArbitrageType.SANDWICH) {
            _executeSandwich(params);
        } else if (params.arbType == ArbitrageType.TRIANGULAR) {
            _executeTriangular(params);
        } else if (params.arbType == ArbitrageType.CROSS_DEX) {
            _executeCrossDEX(params);
        } else {
            // SINGLE_HOP, MULTI_HOP, CUSTOM - generic execution
            _executeSwapSequence(params.swaps);
        }
    }
    
    function _executeSwapSequence(SwapStep[] memory swaps) private {
        for (uint i = 0; i < swaps.length; i++) {
            SwapStep memory step = swaps[i];
            
            // Security check for untrusted DEXes
            if (!trustedDEXes[step.target]) {
                require(step.requireSuccess == false, "Untrusted DEX requires optional execution");
            }
            
            (bool success, bytes memory returnData) = step.target.call{value: step.value}(step.callData);
            
            emit SwapExecuted(step.target, success, i);
            
            if (step.requireSuccess) {
                require(success, string(abi.encodePacked("Swap ", i, " failed: ", returnData)));
            }
        }
    }
    
    function _executeSandwich(ArbitrageParams memory params) private {
        require(params.swaps.length >= 2, "Sandwich needs at least 2 swaps");
        
        // Front-run: Execute first swap
        SwapStep memory frontRun = params.swaps[0];
        (bool success1,) = frontRun.target.call{value: frontRun.value}(frontRun.callData);
        require(success1, "Front-run failed");
        
        // Execute middle swaps if any (user transactions simulated)
        for (uint i = 1; i < params.swaps.length - 1; i++) {
            SwapStep memory step = params.swaps[i];
            (bool success,) = step.target.call{value: step.value}(step.callData);
            if (step.requireSuccess) {
                require(success, "Middle swap failed");
            }
        }
        
        // Back-run: Execute final swap  
        SwapStep memory backRun = params.swaps[params.swaps.length - 1];
        (bool success2,) = backRun.target.call{value: backRun.value}(backRun.callData);
        require(success2, "Back-run failed");
    }
    
    function _executeTriangular(ArbitrageParams memory params) private {
        require(params.swaps.length == 3, "Triangular needs exactly 3 swaps");
        _executeSwapSequence(params.swaps);
    }
    
    function _executeCrossDEX(ArbitrageParams memory params) private {
        require(params.swaps.length == 2, "Cross-DEX needs exactly 2 swaps");
        _executeSwapSequence(params.swaps);
    }
    
    function _calculateProfit(
        ArbitrageParams memory params,
        IERC20[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory initialBalances,
        uint256[] memory feeAmounts
    ) private view returns (uint256 profit) {
        
        if (params.profitToken == params.tokens[0]) {
            // Profit in first flashloan token
            uint256 currentBalance = IERC20(params.tokens[0]).balanceOf(address(this));
            uint256 totalRepay = amounts[0] + feeAmounts[0];
            
            if (currentBalance > totalRepay) {
                profit = currentBalance - totalRepay;
            }
        } else {
            // Profit in different token
            profit = IERC20(params.profitToken).balanceOf(address(this));
        }
    }
    
    function _sendProfit(address profitToken, uint256 profit, address to) private {
        if (profit == 0) return;
        
        if (profitToken == WETH) {
            // Handle WETH -> ETH conversion if requested in extraData
            IWETH(WETH).withdraw(profit);
            (bool success,) = payable(to).call{value: profit}("");
            require(success, "ETH transfer failed");
        } else if (profitToken == address(0)) {
            // Send native ETH
            (bool success,) = payable(to).call{value: profit}("");
            require(success, "ETH transfer failed");
        } else {
            // Send ERC20 token
            IERC20(profitToken).safeTransfer(to, profit);
        }
        
        emit ProfitExtracted(profitToken, profit, to);
    }
    
    // View functions for off-chain calculations
    function estimateGas(ArbitrageParams calldata params) external view returns (uint256) {
        // Estimate gas for the arbitrage execution
        return 21000 + (params.swaps.length * 150000); // Base + per swap estimate
    }
    
    function validateStrategy(ArbitrageParams calldata params) external view returns (bool valid, string memory reason) {
        if (params.deadline < block.timestamp) {
            return (false, "Expired deadline");
        }
        
        if (params.minProfit < minProfitThreshold) {
            return (false, "Profit below threshold");
        }
        
        if (params.swaps.length == 0) {
            return (false, "No swaps provided");
        }
        
        // Additional validation based on arbitrage type
        if (params.arbType == ArbitrageType.TRIANGULAR && params.swaps.length != 3) {
            return (false, "Triangular requires 3 swaps");
        }
        
        if (params.arbType == ArbitrageType.CROSS_DEX && params.swaps.length != 2) {
            return (false, "Cross-DEX requires 2 swaps");
        }
        
        return (true, "");
    }
    
    // Emergency and admin functions
    function setAuthorized(address user, bool auth) external onlyOwner {
        authorized[user] = auth;
    }
    
    function setTrustedDEX(address dex, bool trusted) external onlyOwner {
        trustedDEXes[dex] = trusted;
    }
    
    function setMaxFlashLoanSize(uint256 newMax) external onlyOwner {
        maxFlashLoanSize = newMax;
    }
    
    function setMinProfitThreshold(uint256 newMin) external onlyOwner {
        minProfitThreshold = newMin;
    }
    
    function setEmergencyStop(bool stop) external onlyOwner {
        emergencyStop = stop;
    }
    
    function rescue(address token, uint256 amount) external onlyOwner {
        if (token == address(0)) {
            payable(owner()).transfer(amount > 0 ? amount : address(this).balance);
        } else {
            uint256 balance = IERC20(token).balanceOf(address(this));
            IERC20(token).safeTransfer(owner(), amount > 0 ? amount : balance);
        }
    }
    
    // Batch rescue for multiple tokens
    function rescueBatch(address[] calldata tokens) external onlyOwner {
        for (uint i = 0; i < tokens.length; i++) {
            if (tokens[i] == address(0)) {
                if (address(this).balance > 0) {
                    payable(owner()).transfer(address(this).balance);
                }
            } else {
                uint256 balance = IERC20(tokens[i]).balanceOf(address(this));
                if (balance > 0) {
                    IERC20(tokens[i]).safeTransfer(owner(), balance);
                }
            }
        }
    }
    
    receive() external payable {}
    fallback() external payable {}
}