// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract TokenManager is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant FINANCE_ROLE = keccak256("FINANCE_ROLE");
    
    struct TokenInfo {
        address tokenAddress;
        string symbol;
        uint8 decimals;
        bool isSupported;
        uint256 balance;
        uint256 reserveAmount;
    }
    
    address public payrollCore;
    address[] public supportedTokens;
    mapping(address => TokenInfo) public tokenInfo;
    mapping(address => bool) public isTokenSupported;
    
    uint256 public reservePercentage = 10; // 10% reserve requirement
    
    event TokenAdded(address indexed token, string symbol, uint8 decimals);
    event TokenRemoved(address indexed token);
    event FundsAdded(address indexed token, uint256 amount, address indexed sender);
    event FundsWithdrawn(address indexed token, uint256 amount, address indexed recipient);
    event ReservePercentageUpdated(uint256 oldPercentage, uint256 newPercentage);
    event LowBalanceWarning(address indexed token, uint256 currentBalance, uint256 requiredAmount);
    
    modifier onlyPayrollCore() {
        require(msg.sender == payrollCore, "Only payroll core can call");
        _;
    }
    
    modifier onlyAuthorized() {
        require(
            AccessControl(payrollCore).hasRole(ADMIN_ROLE, msg.sender) ||
            AccessControl(payrollCore).hasRole(FINANCE_ROLE, msg.sender),
            "Not authorized"
        );
        _;
    }
    
    constructor(address _payrollCore, address[] memory _initialTokens) {
        payrollCore = _payrollCore;
        
        // Add ETH as supported token (address(0) represents ETH)
        _addToken(address(0), "ETH", 18);
        
        // Add initial supported tokens
        for (uint i = 0; i < _initialTokens.length; i++) {
            if (_initialTokens[i] != address(0)) {
                _addTokenWithDetails(_initialTokens[i]);
            }
        }
    }
    
    function addSupportedToken(address _token) external onlyAuthorized {
        require(_token != address(0), "Cannot add ETH again");
        require(!isTokenSupported[_token], "Token already supported");
        _addTokenWithDetails(_token);
    }
    
    function removeSupportedToken(address _token) external onlyAuthorized {
        require(_token != address(0), "Cannot remove ETH");
        require(isTokenSupported[_token], "Token not supported");
        require(tokenInfo[_token].balance == 0, "Token has balance, withdraw first");
        
        isTokenSupported[_token] = false;
        tokenInfo[_token].isSupported = false;
        
        // Remove from array
        for (uint i = 0; i < supportedTokens.length; i++) {
            if (supportedTokens[i] == _token) {
                supportedTokens[i] = supportedTokens[supportedTokens.length - 1];
                supportedTokens.pop();
                break;
            }
        }
        
        emit TokenRemoved(_token);
    }
    
    function addFunds(address _token, uint256 _amount) external payable onlyPayrollCore nonReentrant {
        if (_token == address(0)) {
            // ETH deposit
            require(msg.value > 0, "No ETH sent");
            tokenInfo[address(0)].balance += msg.value;
            emit FundsAdded(address(0), msg.value, tx.origin);
        } else {
            // ERC20 deposit
            require(isTokenSupported[_token], "Token not supported");
            require(_amount > 0, "Amount must be positive");
            
            IERC20(_token).safeTransferFrom(tx.origin, address(this), _amount);
            tokenInfo[_token].balance += _amount;
            emit FundsAdded(_token, _amount, tx.origin);
        }
    }
    
    function withdrawFunds(
        address _token,
        address _to,
        uint256 _amount
    ) external onlyAuthorized nonReentrant {
        require(_to != address(0), "Invalid recipient");
        require(_amount > 0, "Amount must be positive");
        require(tokenInfo[_token].balance >= _amount, "Insufficient balance");
        
        // Check reserve requirements
        uint256 afterWithdrawal = tokenInfo[_token].balance - _amount;
        uint256 requiredReserve = (tokenInfo[_token].balance * reservePercentage) / 100;
        require(afterWithdrawal >= requiredReserve, "Would violate reserve requirement");
        
        tokenInfo[_token].balance -= _amount;
        
        if (_token == address(0)) {
            payable(_to).transfer(_amount);
        } else {
            IERC20(_token).safeTransfer(_to, _amount);
        }
        
        emit FundsWithdrawn(_token, _amount, _to);
    }
    
    function processPayment(
        address _token,
        address _to,
        uint256 _amount
    ) external onlyPayrollCore nonReentrant returns (bool) {
        if (!isTokenSupported[_token]) return false;
        if (tokenInfo[_token].balance < _amount) return false;
        
        tokenInfo[_token].balance -= _amount;
        
        try this._executeTransfer(_token, _to, _amount) {
            return true;
        } catch {
            // Revert the balance deduction on failure
            tokenInfo[_token].balance += _amount;
            return false;
        }
    }
    
    function _executeTransfer(address _token, address _to, uint256 _amount) external {
        require(msg.sender == address(this), "Internal function");
        
        if (_token == address(0)) {
            payable(_to).transfer(_amount);
        } else {
            IERC20(_token).safeTransfer(_to, _amount);
        }
    }
    
    function setReservePercentage(uint256 _percentage) external onlyAuthorized {
        require(_percentage <= 50, "Reserve percentage too high");
        uint256 oldPercentage = reservePercentage;
        reservePercentage = _percentage;
        emit ReservePercentageUpdated(oldPercentage, _percentage);
    }
    
    function _addToken(address _token, string memory _symbol, uint8 _decimals) internal {
        tokenInfo[_token] = TokenInfo({
            tokenAddress: _token,
            symbol: _symbol,
            decimals: _decimals,
            isSupported: true,
            balance: 0,
            reserveAmount: 0
        });
        
        supportedTokens.push(_token);
        isTokenSupported[_token] = true;
        
        emit TokenAdded(_token, _symbol, _decimals);
    }
    
    function _addTokenWithDetails(address _token) internal {
        string memory symbol = "TOKEN";
        uint8 decimals = 18;
        
        // Try to get token metadata using IERC20Metadata interface
        try IERC20Metadata(_token).decimals() returns (uint8 _decimals) {
            decimals = _decimals;
        } catch {
            // Use default decimals if not available
        }
        
        try IERC20Metadata(_token).symbol() returns (string memory _symbol) {
            symbol = _symbol;
        } catch {
            // Use default symbol if not available
        }
        
        _addToken(_token, symbol, decimals);
    }
    
    function checkBalanceRequirement(address _token, uint256 _requiredAmount) external view returns (bool sufficient, uint256 currentBalance, uint256 shortfall) {
        currentBalance = tokenInfo[_token].balance;
        sufficient = currentBalance >= _requiredAmount;
        shortfall = sufficient ? 0 : _requiredAmount - currentBalance;
    }
    
    function estimateGasForPayment(address _token, address /* _to */, uint256 /* _amount */) external pure returns (uint256) {
        if (_token == address(0)) {
            return 21000; // Standard ETH transfer gas
        } else {
            return 65000; // Estimate for ERC20 transfer
        }
    }
    
    function getTokenBalance(address _token) external view returns (uint256) {
        return tokenInfo[_token].balance;
    }
    
    function getSupportedTokens() external view returns (address[] memory) {
        return supportedTokens;
    }
    
    function getSupportedTokensCount() external view returns (uint256) {
        return supportedTokens.length;
    }
    
    function getTokenInfo(address _token) external view returns (TokenInfo memory) {
        return tokenInfo[_token];
    }
    
    function getTreasuryOverview() external view returns (
        address[] memory tokens,
        uint256[] memory balances,
        uint256[] memory reserves
    ) {
        uint256 length = supportedTokens.length;
        tokens = new address[](length);
        balances = new uint256[](length);
        reserves = new uint256[](length);
        
        for (uint i = 0; i < length; i++) {
            tokens[i] = supportedTokens[i];
            balances[i] = tokenInfo[supportedTokens[i]].balance;
            reserves[i] = (balances[i] * reservePercentage) / 100;
        }
    }
    
    function checkLowBalance(address _token, uint256 _threshold) external {
        uint256 balance = tokenInfo[_token].balance;
        if (balance < _threshold) {
            emit LowBalanceWarning(_token, balance, _threshold);
        }
    }
    
    // Receive ETH function
    receive() external payable {
        tokenInfo[address(0)].balance += msg.value;
        emit FundsAdded(address(0), msg.value, msg.sender);
    }
}