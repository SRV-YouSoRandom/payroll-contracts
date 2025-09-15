// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./PayrollCore.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract PayrollFactory is Ownable, ReentrancyGuard {
    struct PayrollInstance {
        address payrollAddress;
        string companyName;
        address admin;
        uint256 createdAt;
        bool isActive;
    }
    
    mapping(address => PayrollInstance[]) public userPayrolls;
    mapping(address => bool) public isPayrollInstance;
    PayrollInstance[] public allPayrolls;
    
    event PayrollCreated(
        address indexed payrollAddress,
        address indexed admin,
        string companyName,
        uint256 timestamp
    );
    
    event PayrollDeactivated(address indexed payrollAddress, uint256 timestamp);
    
    constructor() {}
    
    function createPayroll(
        string memory _companyName,
        address[] memory _initialAdmins,
        address[] memory _supportedTokens
    ) external nonReentrant returns (address) {
        require(bytes(_companyName).length > 0, "Company name required");
        require(_initialAdmins.length > 0, "At least one admin required");
        
        PayrollCore newPayroll = new PayrollCore(
            _companyName,
            msg.sender,
            _initialAdmins,
            _supportedTokens
        );
        
        address payrollAddress = address(newPayroll);
        
        PayrollInstance memory instance = PayrollInstance({
            payrollAddress: payrollAddress,
            companyName: _companyName,
            admin: msg.sender,
            createdAt: block.timestamp,
            isActive: true
        });
        
        userPayrolls[msg.sender].push(instance);
        allPayrolls.push(instance);
        isPayrollInstance[payrollAddress] = true;
        
        emit PayrollCreated(payrollAddress, msg.sender, _companyName, block.timestamp);
        
        return payrollAddress;
    }
    
    function deactivatePayroll(address _payrollAddress) external {
        require(isPayrollInstance[_payrollAddress], "Invalid payroll instance");
        
        PayrollCore payroll = PayrollCore(_payrollAddress);
        require(payroll.hasRole(payroll.ADMIN_ROLE(), msg.sender), "Not authorized");
        
        // Update the instance status
        for (uint i = 0; i < allPayrolls.length; i++) {
            if (allPayrolls[i].payrollAddress == _payrollAddress) {
                allPayrolls[i].isActive = false;
                break;
            }
        }
        
        emit PayrollDeactivated(_payrollAddress, block.timestamp);
    }
    
    function getUserPayrolls(address _user) external view returns (PayrollInstance[] memory) {
        return userPayrolls[_user];
    }
    
    function getAllPayrolls() external view returns (PayrollInstance[] memory) {
        return allPayrolls;
    }
    
    function getActivePayrollsCount() external view returns (uint256) {
        uint256 count = 0;
        for (uint i = 0; i < allPayrolls.length; i++) {
            if (allPayrolls[i].isActive) {
                count++;
            }
        }
        return count;
    }
}