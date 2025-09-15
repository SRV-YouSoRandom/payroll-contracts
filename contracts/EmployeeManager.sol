// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract EmployeeManager is AccessControl, ReentrancyGuard {
    enum PaymentSchedule { MONTHLY, WEEKLY, HOURLY }
    
    struct Employee {
        address wallet;
        uint256 baseAmount;
        PaymentSchedule schedule;
        address preferredToken;
        bool isActive;
        uint256 startDate;
        uint256 lastPayment;
        uint256 totalPaid;
        int256 pendingBonus;
        int256 pendingDeduction;
        uint256 advanceRequested;
        bool advanceApproved;
    }
    
    struct BonusDeduction {
        int256 amount;
        string description;
        bool approved;
        address approver;
        uint256 timestamp;
    }
    
    struct AdvanceRequest {
        uint256 amount;
        string reason;
        bool approved;
        address approver;
        uint256 requestDate;
        uint256 approvalDate;
    }
    
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant HR_ROLE = keccak256("HR_ROLE");
    bytes32 public constant FINANCE_ROLE = keccak256("FINANCE_ROLE");
    
    address public payrollCore;
    
    mapping(address => Employee) public employees;
    mapping(address => BonusDeduction[]) public employeeBonusDeductions;
    mapping(address => AdvanceRequest[]) public employeeAdvanceRequests;
    address[] public employeeAddresses;
    
    event EmployeeAdded(address indexed wallet, uint256 baseAmount, PaymentSchedule schedule);
    event EmployeeUpdated(address indexed wallet, uint256 newBaseAmount);
    event EmployeeDeactivated(address indexed wallet, uint256 timestamp);
    event BonusAdded(address indexed employee, int256 amount, string description);
    event AdvanceRequested(address indexed employee, uint256 amount, string reason);
    event AdvanceApproved(address indexed employee, uint256 amount, address approver);
    event PaymentRecorded(address indexed employee, uint256 amount, uint256 timestamp);
    
    modifier onlyPayrollCore() {
        require(msg.sender == payrollCore, "Only payroll core can call");
        _;
    }
    
    modifier onlyAuthorized() {
        require(
            AccessControl(payrollCore).hasRole(ADMIN_ROLE, msg.sender) ||
            AccessControl(payrollCore).hasRole(HR_ROLE, msg.sender),
            "Not authorized"
        );
        _;
    }
    
    modifier onlyFinanceOrAdmin() {
        require(
            AccessControl(payrollCore).hasRole(ADMIN_ROLE, msg.sender) ||
            AccessControl(payrollCore).hasRole(FINANCE_ROLE, msg.sender),
            "Requires admin or finance role"
        );
        _;
    }
    
    constructor(address _payrollCore) {
        payrollCore = _payrollCore;
    }
    
    function addEmployee(
        address _wallet,
        uint256 _baseAmount,
        PaymentSchedule _schedule,
        address _preferredToken
    ) external onlyPayrollCore {
        require(_wallet != address(0), "Invalid wallet address");
        require(_baseAmount > 0, "Base amount must be positive");
        require(!employees[_wallet].isActive, "Employee already exists");
        
        employees[_wallet] = Employee({
            wallet: _wallet,
            baseAmount: _baseAmount,
            schedule: _schedule,
            preferredToken: _preferredToken,
            isActive: true,
            startDate: block.timestamp,
            lastPayment: 0,
            totalPaid: 0,
            pendingBonus: 0,
            pendingDeduction: 0,
            advanceRequested: 0,
            advanceApproved: false
        });
        
        employeeAddresses.push(_wallet);
        
        emit EmployeeAdded(_wallet, _baseAmount, _schedule);
    }
    
    function updateEmployeePayment(
        address _employee,
        uint256 _newBaseAmount,
        PaymentSchedule _newSchedule,
        address _newPreferredToken
    ) external onlyAuthorized {
        require(employees[_employee].isActive, "Employee not active");
        
        employees[_employee].baseAmount = _newBaseAmount;
        employees[_employee].schedule = _newSchedule;
        employees[_employee].preferredToken = _newPreferredToken;
        
        emit EmployeeUpdated(_employee, _newBaseAmount);
    }
    
    function deactivateEmployee(address _employee) external onlyAuthorized {
        require(employees[_employee].isActive, "Employee already inactive");
        employees[_employee].isActive = false;
        emit EmployeeDeactivated(_employee, block.timestamp);
    }
    
    function addBonusDeduction(
        address _employee,
        int256 _amount,
        string memory _description
    ) external onlyAuthorized {
        require(employees[_employee].isActive, "Employee not active");
        
        BonusDeduction memory bonusDeduction = BonusDeduction({
            amount: _amount,
            description: _description,
            approved: false,
            approver: address(0),
            timestamp: block.timestamp
        });
        
        employeeBonusDeductions[_employee].push(bonusDeduction);
        employees[_employee].pendingBonus += _amount;
        
        emit BonusAdded(_employee, _amount, _description);
    }
    
    function approveBonusDeduction(
        address _employee,
        uint256 _index
    ) external onlyFinanceOrAdmin {
        require(_index < employeeBonusDeductions[_employee].length, "Invalid index");
        require(!employeeBonusDeductions[_employee][_index].approved, "Already approved");
        
        employeeBonusDeductions[_employee][_index].approved = true;
        employeeBonusDeductions[_employee][_index].approver = msg.sender;
    }
    
    function requestAdvance(
        uint256 _amount,
        string memory _reason
    ) external {
        require(employees[msg.sender].isActive, "Employee not active");
        require(_amount > 0, "Amount must be positive");
        require(employees[msg.sender].advanceRequested == 0, "Advance already pending");
        
        AdvanceRequest memory request = AdvanceRequest({
            amount: _amount,
            reason: _reason,
            approved: false,
            approver: address(0),
            requestDate: block.timestamp,
            approvalDate: 0
        });
        
        employeeAdvanceRequests[msg.sender].push(request);
        employees[msg.sender].advanceRequested = _amount;
        
        emit AdvanceRequested(msg.sender, _amount, _reason);
    }
    
    function approveAdvance(
        address _employee,
        uint256 _index
    ) external onlyFinanceOrAdmin {
        require(_index < employeeAdvanceRequests[_employee].length, "Invalid index");
        require(!employeeAdvanceRequests[_employee][_index].approved, "Already approved");
        
        employeeAdvanceRequests[_employee][_index].approved = true;
        employeeAdvanceRequests[_employee][_index].approver = msg.sender;
        employeeAdvanceRequests[_employee][_index].approvalDate = block.timestamp;
        employees[_employee].advanceApproved = true;
        
        emit AdvanceApproved(_employee, employeeAdvanceRequests[_employee][_index].amount, msg.sender);
    }
    
    function recordPayment(address _employee, uint256 _amount) external onlyPayrollCore {
        employees[_employee].lastPayment = block.timestamp;
        employees[_employee].totalPaid += _amount;
        
        // Clear advance if it was paid
        if (employees[_employee].advanceApproved) {
            employees[_employee].advanceRequested = 0;
            employees[_employee].advanceApproved = false;
        }
        
        emit PaymentRecorded(_employee, _amount, block.timestamp);
    }
    
    function getEmployee(address _wallet) external view returns (Employee memory) {
        return employees[_wallet];
    }
    
    function getEmployeeBonusDeductions(address _employee) external view returns (BonusDeduction[] memory) {
        return employeeBonusDeductions[_employee];
    }
    
    function getEmployeeAdvanceRequests(address _employee) external view returns (AdvanceRequest[] memory) {
        return employeeAdvanceRequests[_employee];
    }
    
    function getAllActiveEmployees() external view returns (address[] memory) {
        uint256 activeCount = 0;
        for (uint i = 0; i < employeeAddresses.length; i++) {
            if (employees[employeeAddresses[i]].isActive) {
                activeCount++;
            }
        }
        
        address[] memory activeEmployees = new address[](activeCount);
        uint256 index = 0;
        for (uint i = 0; i < employeeAddresses.length; i++) {
            if (employees[employeeAddresses[i]].isActive) {
                activeEmployees[index] = employeeAddresses[i];
                index++;
            }
        }
        
        return activeEmployees;
    }
    
    function getTotalEmployees() external view returns (uint256) {
        uint256 activeCount = 0;
        for (uint i = 0; i < employeeAddresses.length; i++) {
            if (employees[employeeAddresses[i]].isActive) {
                activeCount++;
            }
        }
        return activeCount;
    }
    
    function isPaymentDue(address _employee) external view returns (bool) {
        Employee memory emp = employees[_employee];
        if (!emp.isActive) return false;
        
        uint256 timeSinceLastPayment = block.timestamp - emp.lastPayment;
        
        if (emp.schedule == PaymentSchedule.MONTHLY) {
            return timeSinceLastPayment >= 30 days;
        } else if (emp.schedule == PaymentSchedule.WEEKLY) {
            return timeSinceLastPayment >= 7 days;
        } else { // HOURLY
            return timeSinceLastPayment >= 1 hours;
        }
    }
    
    function calculatePaymentAmount(address _employee) external view returns (uint256) {
        Employee memory emp = employees[_employee];
        uint256 baseAmount = emp.baseAmount;
        
        // Add approved bonuses and subtract deductions
        int256 adjustments = 0;
        BonusDeduction[] memory bonusDeductions = employeeBonusDeductions[_employee];
        
        for (uint i = 0; i < bonusDeductions.length; i++) {
            if (bonusDeductions[i].approved) {
                adjustments += bonusDeductions[i].amount;
            }
        }
        
        // Handle advance payments
        if (emp.advanceApproved) {
            baseAmount += emp.advanceRequested;
        }
        
        return uint256(int256(baseAmount) + adjustments);
    }
}