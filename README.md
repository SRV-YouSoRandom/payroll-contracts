# Payroll Contracts

A comprehensive Solidity-based payroll management system built for Ethereum. This project provides a modular, role-based smart contract architecture for managing employee payroll, token payments, and audit trails.

## Overview

Payroll Contracts enables organizations to manage employee payments on-chain with support for:

- **Multi-token payments** (ETH and ERC20 tokens)
- **Flexible payment schedules** (monthly, weekly, hourly)
- **Role-based access control** (Admin, HR, Finance, Employee)
- **Batch payments** for efficient bulk processing
- **Bonus and deduction management**
- **Advance payment requests**
- **Comprehensive audit logging**
- **Emergency controls** (pause, withdraw)

## Architecture

The system consists of 8 modular contracts:

```
┌─────────────────────────────────────────────────────────────┐
│                      PayrollFactory                         │
│            (Deploys new payroll instances)                  │
└─────────────────────────┬───────────────────────────────────┘
                          │ creates
                          ▼
┌─────────────────────────────────────────────────────────────┐
│                       PayrollCore                           │
│              (Main orchestrator contract)                   │
│  ┌─────────────┬─────────────┬─────────────┬─────────────┐ │
│  │   Roles     │   Pausable  │ Reentrancy  │             │ │
│  │ Management  │   Control   │   Guard     │             │ │
│  └─────────────┴─────────────┴─────────────┴─────────────┘ │
└───────────┬─────────────┬─────────────┬─────────────┬───────┘
            │             │             │             │
            ▼             ▼             ▼             ▼
    ┌───────────┐  ┌───────────┐  ┌───────────┐  ┌───────────┐
    │ Employee  │  │   Token   │  │  Payment  │  │   Audit   │
    │  Manager  │  │  Manager  │  │ Processor │  │  Logger   │
    └───────────┘  └───────────┘  └─────┬─────┘  └───────────┘
                                        │
                          ┌─────────────┴─────────────┐
                          ▼                           ▼
                  ┌───────────┐               ┌─────────────┐
                  │  Payment  │               │    Batch    │
                  │  Executor │               │   Payment   │
                  └───────────┘               │   Manager   │
                                              └─────────────┘
```

### Core Contracts

| Contract | Description |
|----------|-------------|
| `PayrollCore` | Main entry point; orchestrates employee management, payments, and emergency controls |
| `PayrollFactory` | Factory contract for deploying new payroll instances per organization |
| `EmployeeManager` | Manages employee data, payment schedules, bonuses, deductions, and advances |
| `TokenManager` | Handles multi-token treasury operations (ETH/ERC20 deposits, withdrawals, payments) |
| `PaymentProcessor` | Processes individual and batch payments with retry logic |
| `PaymentExecutor` | Core payment execution logic with receipt generation |
| `BatchPaymentManager` | Efficient batch payment processing with approval workflows |
| `AuditLogger` | Comprehensive audit trail for compliance and transparency |

## Roles & Permissions

| Role | Permissions |
|------|-------------|
| `DEFAULT_ADMIN_ROLE` | Full system control, role management, emergency functions |
| `ADMIN_ROLE` | Emergency pause/unpause, grant roles, upgrade components |
| `HR_ROLE` | Add/update/deactivate employees |
| `FINANCE_ROLE` | Process payments, manage funds, approve advances |
| `EMPLOYEE_ROLE` | View own data, request advances |

## Features

### Employee Management
- Add employees with wallet address, base salary, and payment schedule
- Update payment details and preferred token
- Deactivate employees
- Track payment history and totals

### Payment Schedules
- Monthly (30 days)
- Weekly (7 days)
- Hourly (1 hour)

### Multi-Token Support
- Native ETH payments
- ERC20 token payments
- Dynamic token addition/removal
- Reserve percentage requirements
- Low balance warnings

### Bonus & Deductions
- Add bonuses (positive amounts)
- Apply deductions (negative amounts)
- Approval workflow for adjustments
- Track pending adjustments

### Advance Payments
- Employees can request salary advances
- Finance/Admin approval required
- Automatic integration with next payroll

### Batch Payments
- Create batch payments for multiple employees
- Optional approval workflow
- Track success/failure per payment

### Audit & Compliance
- Comprehensive action logging
- Query logs by actor, action, time range
- Generate compliance reports
- Export audit trails

### Emergency Controls
- Pause/unpause all operations
- Emergency withdrawal of funds
- Component upgrade paths

## Installation

### Prerequisites
- Node.js 18+
- npm or yarn
- Foundry or Hardhat (for testing/deployment)

### Clone & Install

```bash
git clone https://github.com/SRV-YouSoRandom/payroll-contracts.git
cd payroll-contracts
npm install
```

## Usage

### Deploy via Factory

```solidity
// Deploy factory
PayrollFactory factory = new PayrollFactory();

// Create a new payroll instance
address[] memory admins = new address[](1);
admins[0] = 0x...; // Admin address

address[] memory tokens = new address[](2);
tokens[0] = address(0); // ETH
tokens[1] = 0x...; // USDC address

address payrollAddress = factory.createPayroll(
    "My Company",
    admins,
    tokens
);

PayrollCore payroll = PayrollCore(payrollAddress);
```

### Add Employee

```solidity
// Grant HR role first
payroll.grantHRRole(hrAddress);

// Add employee (as HR or Admin)
payroll.addEmployee(
    employeeWallet,
    5000 * 10**18,        // Base amount (in token decimals)
    EmployeeManager.PaymentSchedule.MONTHLY,
    usdcAddress           // Preferred payment token
);
```

### Fund the Payroll

```solidity
// Add ETH
payroll.addFunds{value: 10 ether}(address(0), 0);

// Add ERC20 (approve first)
IERC20(usdc).approve(address(payroll), amount);
payroll.addFunds(usdc, amount);
```

### Process Payroll

```solidity
// Grant finance role
payroll.grantFinanceRole(financeAddress);

// Process scheduled payments (as Finance or Admin)
payroll.processPayroll();
```

### Create Batch Payment

```solidity
address[] memory employees = new address[](3);
employees[0] = emp1;
employees[1] = emp2;
employees[2] = emp3;

uint256[] memory amounts = new uint256[](3);
amounts[0] = 1000 * 10**18;
amounts[1] = 2000 * 10**18;
amounts[2] = 1500 * 10**18;

uint256 batchId = paymentProcessor.createBatchPayment(
    employees,
    usdcAddress,
    amounts,
    PaymentProcessor.PaymentType.SALARY
);

// Approve (if required)
paymentProcessor.approveBatchPayment(batchId);

// Process
paymentProcessor.processBatchPayment(batchId);
```

## Contract Addresses (After Deployment)

| Contract | Description |
|----------|-------------|
| PayrollCore | Main payroll contract |
| EmployeeManager | Employee data management |
| TokenManager | Treasury & token operations |
| PaymentProcessor | Payment processing |
| PaymentExecutor | Core execution logic |
| BatchPaymentManager | Batch operations |
| AuditLogger | Audit trail |

## Security

- **ReentrancyGuard** protection on all state-changing functions
- **Pausable** for emergency stops
- **AccessControl** for granular permissions
- **SafeERC20** for safe token transfers
- Reserve requirements to prevent empty payouts

## Testing

```bash
# Run all tests
npm test

# Run with coverage
npm run coverage
```

## License

MIT License - see [LICENSE](LICENSE) for details.

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests
5. Submit a pull request

## Author

[SRV-YouSoRandom](https://github.com/SRV-YouSoRandom)