// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./EmployeeManager.sol";
import "./TokenManager.sol";
import "./AuditLogger.sol";

contract PaymentProcessor is AccessControl, ReentrancyGuard {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant FINANCE_ROLE = keccak256("FINANCE_ROLE");
    
    enum PaymentStatus { PENDING, SUCCESSFUL, FAILED, RETRYING }
    enum PaymentType { SALARY, BONUS, ADVANCE, DEDUCTION }
    
    struct PaymentRecord {
        address employee;
        address token;
        uint256 amount;
        uint256 timestamp;
        PaymentType paymentType;
        PaymentStatus status;
        string receiptHash;
        uint256 gasUsed;
        uint256 retryCount;
        string failureReason;
    }
    
    struct BatchPayment {
        address[] employees;
        address token;
        uint256[] amounts;
        PaymentType paymentType;
        bool requiresApproval;
        bool approved;
        address approver;
        uint256 timestamp;
    }
    
    address public payrollCore;
    EmployeeManager public employeeManager;
    TokenManager public tokenManager;
    AuditLogger public auditLogger;
    
    PaymentRecord[] public paymentHistory;
    mapping(address => PaymentRecord[]) public employeePaymentHistory;
    mapping(address => uint256) public failedPaymentCount;
    
    BatchPayment[] public batchPayments;
    mapping(uint256 => bool) public batchProcessed;
    
    uint256 public maxRetryAttempts = 3;
    uint256 public retryDelay = 1 hours;
    bool public requireApprovalForPayments = true;
    
    event PaymentProcessed(
        address indexed employee,
        address indexed token,
        uint256 amount,
        PaymentType paymentType,
        PaymentStatus status,
        uint256 gasUsed
    );
    
    event PaymentFailed(
        address indexed employee,
        address indexed token,
        uint256 amount,
        string reason,
        uint256 retryCount
    );
    
    event BatchPaymentCreated(uint256 indexed batchId, uint256 employeeCount, address token);
    event BatchPaymentApproved(uint256 indexed batchId, address approver);
    event BatchPaymentProcessed(uint256 indexed batchId, uint256 successCount, uint256 failureCount);
    
    event ReceiptGenerated(address indexed employee, uint256 paymentId, string ipfsHash);
    event PaymentRetried(address indexed employee, uint256 paymentId, uint256 retryCount);
    
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
    
    constructor(address _payrollCore) {
        payrollCore = _payrollCore;
    }
    
    function setEmployeeManager(address _employeeManager) external onlyPayrollCore {
        employeeManager = EmployeeManager(_employeeManager);
    }
    
    function setTokenManager(address payable _tokenManager) external onlyPayrollCore {
        tokenManager = TokenManager(_tokenManager);
    }
    
    function setAuditLogger(address _auditLogger) external onlyPayrollCore {
        auditLogger = AuditLogger(_auditLogger);
    }
    
    function setMaxRetryAttempts(uint256 _maxRetries) external onlyAuthorized {
        maxRetryAttempts = _maxRetries;
    }
    
    function setRetryDelay(uint256 _delaySeconds) external onlyAuthorized {
        retryDelay = _delaySeconds;
    }
    
    function setRequireApproval(bool _requireApproval) external onlyAuthorized {
        requireApprovalForPayments = _requireApproval;
    }
    
    function processSinglePayment(
        address _employee,
        address _token,
        uint256 _amount,
        PaymentType _paymentType
    ) external onlyAuthorized nonReentrant returns (bool success) {
        require(employeeManager.getEmployee(_employee).isActive, "Employee not active");
        
        uint256 gasStart = gasleft();
        
        PaymentRecord memory record = PaymentRecord({
            employee: _employee,
            token: _token,
            amount: _amount,
            timestamp: block.timestamp,
            paymentType: _paymentType,
            status: PaymentStatus.PENDING,
            receiptHash: "",
            gasUsed: 0,
            retryCount: 0,
            failureReason: ""
        });
        
        success = _executePayment(record);
        
        record.gasUsed = gasStart - gasleft();
        record.status = success ? PaymentStatus.SUCCESSFUL : PaymentStatus.FAILED;
        
        if (success) {
            employeeManager.recordPayment(_employee, _amount);
            record.receiptHash = _generateReceipt(record);
        } else {
            record.failureReason = "Payment execution failed";
            failedPaymentCount[_employee]++;
        }
        
        paymentHistory.push(record);
        employeePaymentHistory[_employee].push(record);
        
        _logPayment(record);
        
        emit PaymentProcessed(_employee, _token, _amount, _paymentType, record.status, record.gasUsed);
        
        return success;
    }
    
    function processScheduledPayments() external onlyPayrollCore nonReentrant {
        address[] memory activeEmployees = employeeManager.getAllActiveEmployees();
        uint256 successCount = 0;
        uint256 failureCount = 0;
        
        for (uint i = 0; i < activeEmployees.length; i++) {
            address employee = activeEmployees[i];
            
            if (employeeManager.isPaymentDue(employee)) {
                EmployeeManager.Employee memory emp = employeeManager.getEmployee(employee);
                uint256 paymentAmount = employeeManager.calculatePaymentAmount(employee);
                
                bool success = _processSinglePaymentInternal(
                    employee,
                    emp.preferredToken,
                    paymentAmount,
                    PaymentType.SALARY
                );
                
                if (success) {
                    successCount++;
                } else {
                    failureCount++;
                }
            }
        }
        
        auditLogger.logAction(
            msg.sender,
            "SCHEDULED_PAYMENTS_PROCESSED",
            abi.encode(successCount, failureCount, block.timestamp)
        );
    }
    
    function createBatchPayment(
        address[] memory _employees,
        address _token,
        uint256[] memory _amounts,
        PaymentType _paymentType
    ) external onlyAuthorized returns (uint256 batchId) {
        require(_employees.length == _amounts.length, "Array length mismatch");
        require(_employees.length > 0, "No employees specified");
        
        BatchPayment memory batch = BatchPayment({
            employees: _employees,
            token: _token,
            amounts: _amounts,
            paymentType: _paymentType,
            requiresApproval: requireApprovalForPayments,
            approved: !requireApprovalForPayments,
            approver: requireApprovalForPayments ? address(0) : msg.sender,
            timestamp: block.timestamp
        });
        
        batchPayments.push(batch);
        batchId = batchPayments.length - 1;
        
        emit BatchPaymentCreated(batchId, _employees.length, _token);
        
        return batchId;
    }
    
    function approveBatchPayment(uint256 _batchId) external onlyAuthorized {
        require(_batchId < batchPayments.length, "Invalid batch ID");
        require(!batchPayments[_batchId].approved, "Batch already approved");
        require(batchPayments[_batchId].requiresApproval, "Batch doesn't require approval");
        
        batchPayments[_batchId].approved = true;
        batchPayments[_batchId].approver = msg.sender;
        
        emit BatchPaymentApproved(_batchId, msg.sender);
    }
    
    function processBatchPayment(uint256 _batchId) external onlyAuthorized nonReentrant {
        require(_batchId < batchPayments.length, "Invalid batch ID");
        require(batchPayments[_batchId].approved, "Batch not approved");
        require(!batchProcessed[_batchId], "Batch already processed");
        
        BatchPayment memory batch = batchPayments[_batchId];
        uint256 successCount = 0;
        uint256 failureCount = 0;
        
        for (uint i = 0; i < batch.employees.length; i++) {
            bool success = _processSinglePaymentInternal(
                batch.employees[i],
                batch.token,
                batch.amounts[i],
                batch.paymentType
            );
            
            if (success) {
                successCount++;
            } else {
                failureCount++;
            }
        }
        
        batchProcessed[_batchId] = true;
        
        emit BatchPaymentProcessed(_batchId, successCount, failureCount);
        
        auditLogger.logAction(
            msg.sender,
            "BATCH_PAYMENT_PROCESSED",
            abi.encode(_batchId, successCount, failureCount, block.timestamp)
        );
    }
    
    function retryFailedPayment(uint256 _paymentId) external onlyAuthorized {
        require(_paymentId < paymentHistory.length, "Invalid payment ID");
        
        PaymentRecord storage record = paymentHistory[_paymentId];
        require(record.status == PaymentStatus.FAILED, "Payment not failed");
        require(record.retryCount < maxRetryAttempts, "Max retries exceeded");
        require(block.timestamp >= record.timestamp + (retryDelay * (record.retryCount + 1)), "Retry delay not met");
        
        record.status = PaymentStatus.RETRYING;
        record.retryCount++;
        
        uint256 gasStart = gasleft();
        bool success = _executePayment(record);
        record.gasUsed += gasStart - gasleft();
        
        if (success) {
            record.status = PaymentStatus.SUCCESSFUL;
            employeeManager.recordPayment(record.employee, record.amount);
            record.receiptHash = _generateReceipt(record);
            failedPaymentCount[record.employee]--;
        } else {
            record.status = PaymentStatus.FAILED;
            record.failureReason = "Retry failed";
        }
        
        emit PaymentRetried(record.employee, _paymentId, record.retryCount);
        _logPayment(record);
    }
    
    function _processSinglePaymentInternal(
        address _employee,
        address _token,
        uint256 _amount,
        PaymentType _paymentType
    ) internal returns (bool success) {
        uint256 gasStart = gasleft();
        
        PaymentRecord memory record = PaymentRecord({
            employee: _employee,
            token: _token,
            amount: _amount,
            timestamp: block.timestamp,
            paymentType: _paymentType,
            status: PaymentStatus.PENDING,
            receiptHash: "",
            gasUsed: 0,
            retryCount: 0,
            failureReason: ""
        });
        
        success = _executePayment(record);
        
        record.gasUsed = gasStart - gasleft();
        record.status = success ? PaymentStatus.SUCCESSFUL : PaymentStatus.FAILED;
        
        if (success) {
            employeeManager.recordPayment(_employee, _amount);
            record.receiptHash = _generateReceipt(record);
        } else {
            record.failureReason = "Payment execution failed";
            failedPaymentCount[_employee]++;
        }
        
        paymentHistory.push(record);
        employeePaymentHistory[_employee].push(record);
        
        _logPayment(record);
        
        emit PaymentProcessed(_employee, _token, _amount, _paymentType, record.status, record.gasUsed);
        
        return success;
    }
    
    function _executePayment(PaymentRecord memory _record) internal returns (bool) {
        return tokenManager.processPayment(_record.token, _record.employee, _record.amount);
    }
    
    function _generateReceipt(PaymentRecord memory _record) internal returns (string memory) {
        // Generate a simple receipt hash (in production, this would upload to IPFS)
        string memory receiptData = string(abi.encodePacked(
            "Employee: ", _addressToString(_record.employee),
            " Amount: ", _uint256ToString(_record.amount),
            " Token: ", _addressToString(_record.token),
            " Timestamp: ", _uint256ToString(_record.timestamp)
        ));
        
        bytes32 hash = keccak256(abi.encodePacked(receiptData));
        string memory receiptHash = _bytes32ToString(hash);
        
        emit ReceiptGenerated(_record.employee, paymentHistory.length, receiptHash);
        
        return receiptHash;
    }
    
    function _logPayment(PaymentRecord memory _record) internal {
        auditLogger.logAction(
            _record.employee,
            "PAYMENT_PROCESSED",
            abi.encode(
                _record.token,
                _record.amount,
                _record.paymentType,
                _record.status,
                _record.timestamp
            )
        );
    }
    
    // Utility functions for string conversion
    function _addressToString(address _addr) internal pure returns (string memory) {
        bytes32 value = bytes32(uint256(uint160(_addr)));
        bytes memory alphabet = "0123456789abcdef";
        bytes memory str = new bytes(42);
        str[0] = '0';
        str[1] = 'x';
        for (uint256 i = 0; i < 20; i++) {
            str[2+i*2] = alphabet[uint8(value[i + 12] >> 4)];
            str[3+i*2] = alphabet[uint8(value[i + 12] & 0x0f)];
        }
        return string(str);
    }
    
    function _uint256ToString(uint256 _value) internal pure returns (string memory) {
        if (_value == 0) return "0";
        uint256 temp = _value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (_value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(_value % 10)));
            _value /= 10;
        }
        return string(buffer);
    }
    
    function _bytes32ToString(bytes32 _bytes32) internal pure returns (string memory) {
        uint8 i = 0;
        while(i < 32 && _bytes32[i] != 0) {
            i++;
        }
        bytes memory bytesArray = new bytes(i);
        for (i = 0; i < 32 && _bytes32[i] != 0; i++) {
            bytesArray[i] = _bytes32[i];
        }
        return string(bytesArray);
    }
    
    // View functions
    function getPaymentHistory(address _employee) external view returns (PaymentRecord[] memory) {
        return employeePaymentHistory[_employee];
    }
    
    function getPaymentRecord(uint256 _paymentId) external view returns (PaymentRecord memory) {
        require(_paymentId < paymentHistory.length, "Invalid payment ID");
        return paymentHistory[_paymentId];
    }
    
    function getBatchPayment(uint256 _batchId) external view returns (BatchPayment memory) {
        require(_batchId < batchPayments.length, "Invalid batch ID");
        return batchPayments[_batchId];
    }
    
    function getFailedPaymentCount(address _employee) external view returns (uint256) {
        return failedPaymentCount[_employee];
    }
    
    function getTotalPayments() external view returns (uint256) {
        return paymentHistory.length;
    }
    
    function getTotalBatchPayments() external view returns (uint256) {
        return batchPayments.length;
    }
    
    function estimatePaymentGas(address _token, address _employee, uint256 _amount) external view returns (uint256) {
        return tokenManager.estimateGasForPayment(_token, _employee, _amount);
    }
}