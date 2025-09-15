// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./EmployeeManager.sol";
import "./TokenManager.sol";
import "./PaymentProcessor.sol";
import "./AuditLogger.sol";

contract PayrollCore is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant HR_ROLE = keccak256("HR_ROLE");
    bytes32 public constant FINANCE_ROLE = keccak256("FINANCE_ROLE");
    bytes32 public constant EMPLOYEE_ROLE = keccak256("EMPLOYEE_ROLE");
    
    string public companyName;
    uint256 public immutable deploymentTime;
    
    EmployeeManager public employeeManager;
    TokenManager public tokenManager;
    PaymentProcessor public paymentProcessor;
    AuditLogger public auditLogger;
    
    event PayrollSystemInitialized(string companyName, uint256 timestamp);
    event EmergencyPaused(address indexed admin, uint256 timestamp);
    event EmergencyUnpaused(address indexed admin, uint256 timestamp);
    event ComponentUpgraded(string component, address oldAddress, address newAddress);
    
    modifier onlyAdminOrFinance() {
        require(
            hasRole(ADMIN_ROLE, msg.sender) || hasRole(FINANCE_ROLE, msg.sender),
            "Requires admin or finance role"
        );
        _;
    }
    
    modifier onlyAdminOrHR() {
        require(
            hasRole(ADMIN_ROLE, msg.sender) || hasRole(HR_ROLE, msg.sender),
            "Requires admin or HR role"
        );
        _;
    }
    
    constructor(
        string memory _companyName,
        address _deployer,
        address[] memory _initialAdmins,
        address[] memory _supportedTokens
    ) {
        require(bytes(_companyName).length > 0, "Company name required");
        
        companyName = _companyName;
        deploymentTime = block.timestamp;
        
        // Set up roles
        _grantRole(DEFAULT_ADMIN_ROLE, _deployer);
        _grantRole(ADMIN_ROLE, _deployer);
        
        for (uint i = 0; i < _initialAdmins.length; i++) {
            _grantRole(ADMIN_ROLE, _initialAdmins[i]);
        }
        
        // Deploy component contracts
        employeeManager = new EmployeeManager(address(this));
        tokenManager = new TokenManager(address(this), _supportedTokens);
        paymentProcessor = new PaymentProcessor(address(this));
        auditLogger = new AuditLogger(address(this));
        
        // Set component references
        paymentProcessor.setEmployeeManager(address(employeeManager));
        paymentProcessor.setTokenManager(payable (address(tokenManager)));
        paymentProcessor.setAuditLogger(address(auditLogger));
        
        emit PayrollSystemInitialized(_companyName, block.timestamp);
    }
    
    // Emergency functions
    function emergencyPause() external onlyRole(ADMIN_ROLE) {
        _pause();
        auditLogger.logAction(
            msg.sender,
            "EMERGENCY_PAUSE",
            abi.encode(block.timestamp)
        );
        emit EmergencyPaused(msg.sender, block.timestamp);
    }
    
    function emergencyUnpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
        auditLogger.logAction(
            msg.sender,
            "EMERGENCY_UNPAUSE",
            abi.encode(block.timestamp)
        );
        emit EmergencyUnpaused(msg.sender, block.timestamp);
    }
    
    function emergencyWithdraw(
        address _token,
        address _to,
        uint256 _amount
    ) external onlyRole(ADMIN_ROLE) whenPaused {
        require(_to != address(0), "Invalid recipient");
        
        if (_token == address(0)) {
            // ETH withdrawal
            require(address(this).balance >= _amount, "Insufficient ETH balance");
            payable(_to).transfer(_amount);
        } else {
            // ERC20 withdrawal
            IERC20(_token).safeTransfer(_to, _amount);
        }
        
        auditLogger.logAction(
            msg.sender,
            "EMERGENCY_WITHDRAW",
            abi.encode(_token, _to, _amount, block.timestamp)
        );
    }
    
    // Role management functions
    function grantHRRole(address _account) external onlyRole(ADMIN_ROLE) {
        grantRole(HR_ROLE, _account);
        auditLogger.logAction(
            msg.sender,
            "GRANT_HR_ROLE",
            abi.encode(_account, block.timestamp)
        );
    }
    
    function grantFinanceRole(address _account) external onlyRole(ADMIN_ROLE) {
        grantRole(FINANCE_ROLE, _account);
        auditLogger.logAction(
            msg.sender,
            "GRANT_FINANCE_ROLE",
            abi.encode(_account, block.timestamp)
        );
    }
    
    function grantEmployeeRole(address _account) public onlyAdminOrHR {
        grantRole(EMPLOYEE_ROLE, _account);
        auditLogger.logAction(
            msg.sender,
            "GRANT_EMPLOYEE_ROLE",
            abi.encode(_account, block.timestamp)
        );
    }
    
    // Component upgrade functions (for future upgradability)
    function upgradeEmployeeManager(address _newManager) external onlyRole(ADMIN_ROLE) {
        address oldManager = address(employeeManager);
        employeeManager = EmployeeManager(_newManager);
        paymentProcessor.setEmployeeManager(_newManager);
        emit ComponentUpgraded("EmployeeManager", oldManager, _newManager);
    }
    
    function upgradeTokenManager(address payable _newManager) external onlyRole(ADMIN_ROLE) {
        address oldManager = address(tokenManager);
        tokenManager = TokenManager(_newManager);
        paymentProcessor.setTokenManager(_newManager);
        emit ComponentUpgraded("TokenManager", oldManager, _newManager);
    }
    
    function upgradePaymentProcessor(address _newProcessor) external onlyRole(ADMIN_ROLE) {
        address oldProcessor = address(paymentProcessor);
        paymentProcessor = PaymentProcessor(_newProcessor);
        emit ComponentUpgraded("PaymentProcessor", oldProcessor, _newProcessor);
    }
    
    // Delegate functions to components
    function addEmployee(
        address _wallet,
        uint256 _baseAmount,
        EmployeeManager.PaymentSchedule _schedule,
        address _preferredToken
    ) external onlyAdminOrHR whenNotPaused {
        employeeManager.addEmployee(_wallet, _baseAmount, _schedule, _preferredToken);
        grantEmployeeRole(_wallet);
        
        auditLogger.logAction(
            msg.sender,
            "EMPLOYEE_ADDED",
            abi.encode(_wallet, _baseAmount, _schedule, _preferredToken, block.timestamp)
        );
    }
    
    function processPayroll() external onlyAdminOrFinance whenNotPaused nonReentrant {
        paymentProcessor.processScheduledPayments();
    }
    
    function addFunds(address _token, uint256 _amount) external payable onlyAdminOrFinance whenNotPaused {
        tokenManager.addFunds{value: msg.value}(_token, _amount);
    }
    
    // View functions
    function getSystemStatus() external view returns (
        string memory _companyName,
        bool _isPaused,
        uint256 _totalEmployees,
        uint256 _supportedTokensCount,
        uint256 _deploymentTime
    ) {
        return (
            companyName,
            paused(),
            employeeManager.getTotalEmployees(),
            tokenManager.getSupportedTokensCount(),
            deploymentTime
        );
    }
    
    // Receive ETH
    receive() external payable {
        tokenManager.addFunds{value: msg.value}(address(0), msg.value);
    }
}