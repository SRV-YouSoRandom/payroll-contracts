// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./PaymentExecutor.sol";

/**
 * @title BatchPaymentManager
 * @dev Handles batch payment operations
 */
contract BatchPaymentManager is AccessControl, ReentrancyGuard {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant FINANCE_ROLE = keccak256("FINANCE_ROLE");
    
    struct BatchPayment {
        address[] employees;
        address token;
        uint256[] amounts;
        PaymentExecutor.PaymentType paymentType;
        bool requiresApproval;
        bool approved;
        address approver;
        uint256 timestamp;
    }
    
    address public payrollCore;
    PaymentExecutor public paymentExecutor;
    AuditLogger public auditLogger;
    
    BatchPayment[] public batchPayments;
    mapping(uint256 => bool) public batchProcessed;
    
    bool public requireApprovalForPayments = true;
    
    event BatchPaymentCreated(uint256 indexed batchId, uint256 employeeCount, address token);
    event BatchPaymentApproved(uint256 indexed batchId, address approver);
    event BatchPaymentProcessed(uint256 indexed batchId, uint256 successCount, uint256 failureCount);
    
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
    
    function setPaymentExecutor(address _paymentExecutor) external onlyPayrollCore {
        paymentExecutor = PaymentExecutor(_paymentExecutor);
    }
    
    function setAuditLogger(address _auditLogger) external onlyPayrollCore {
        auditLogger = AuditLogger(_auditLogger);
    }
    
    function setRequireApproval(bool _requireApproval) external onlyAuthorized {
        requireApprovalForPayments = _requireApproval;
    }
    
    function createBatchPayment(
        address[] memory _employees,
        address _token,
        uint256[] memory _amounts,
        PaymentExecutor.PaymentType _paymentType
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
            bool success = paymentExecutor.processSinglePayment(
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
    
    function getBatchPayment(uint256 _batchId) external view returns (BatchPayment memory) {
        require(_batchId < batchPayments.length, "Invalid batch ID");
        return batchPayments[_batchId];
    }
    
    function getTotalBatchPayments() external view returns (uint256) {
        return batchPayments.length;
    }
    
    function isBatchProcessed(uint256 _batchId) external view returns (bool) {
        return batchProcessed[_batchId];
    }
}