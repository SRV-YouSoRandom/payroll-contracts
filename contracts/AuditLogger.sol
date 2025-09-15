// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/AccessControl.sol";

contract AuditLogger is AccessControl {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    
    struct AuditLog {
        address actor;
        string action;
        bytes data;
        uint256 timestamp;
        uint256 blockNumber;
        bytes32 transactionHash;
    }
    
    address public payrollCore;
    
    AuditLog[] public auditTrail;
    mapping(address => uint256[]) public actorLogs;
    mapping(string => uint256[]) public actionLogs;
    mapping(uint256 => uint256[]) public dailyLogs;
    
    event ActionLogged(
        address indexed actor,
        string indexed action,
        uint256 timestamp,
        uint256 logIndex
    );
    
    modifier onlyPayrollCore() {
        require(msg.sender == payrollCore, "Only payroll core can call");
        _;
    }
    
    modifier onlyAuthorized() {
        require(
            msg.sender == payrollCore ||
            AccessControl(payrollCore).hasRole(ADMIN_ROLE, msg.sender),
            "Not authorized"
        );
        _;
    }
    
    constructor(address _payrollCore) {
        payrollCore = _payrollCore;
    }
    
    function logAction(
        address _actor,
        string memory _action,
        bytes memory _data
    ) external onlyAuthorized {
        uint256 logIndex = auditTrail.length;
        uint256 day = block.timestamp / 86400; // Get day number
        
        AuditLog memory log = AuditLog({
            actor: _actor,
            action: _action,
            data: _data,
            timestamp: block.timestamp,
            blockNumber: block.number,
            transactionHash: blockhash(block.number - 1)
        });
        
        auditTrail.push(log);
        actorLogs[_actor].push(logIndex);
        actionLogs[_action].push(logIndex);
        dailyLogs[day].push(logIndex);
        
        emit ActionLogged(_actor, _action, block.timestamp, logIndex);
    }
    
    function getAuditLog(uint256 _index) external view returns (AuditLog memory) {
        require(_index < auditTrail.length, "Invalid log index");
        return auditTrail[_index];
    }
    
    function getActorLogs(address _actor) external view returns (uint256[] memory) {
        return actorLogs[_actor];
    }
    
    function getActionLogs(string memory _action) external view returns (uint256[] memory) {
        return actionLogs[_action];
    }
    
    function getDailyLogs(uint256 _day) external view returns (uint256[] memory) {
        return dailyLogs[_day];
    }
    
    function getLogsInRange(
        uint256 _startIndex,
        uint256 _endIndex
    ) external view returns (AuditLog[] memory logs) {
        require(_startIndex <= _endIndex, "Invalid range");
        require(_endIndex < auditTrail.length, "End index out of bounds");
        
        uint256 length = _endIndex - _startIndex + 1;
        logs = new AuditLog[](length);
        
        for (uint256 i = 0; i < length; i++) {
            logs[i] = auditTrail[_startIndex + i];
        }
        
        return logs;
    }
    
    function getLogsByTimeRange(
        uint256 _startTime,
        uint256 _endTime
    ) external view returns (AuditLog[] memory logs) {
        require(_startTime <= _endTime, "Invalid time range");
        
        // Count matching logs first
        uint256 count = 0;
        for (uint256 i = 0; i < auditTrail.length; i++) {
            if (auditTrail[i].timestamp >= _startTime && auditTrail[i].timestamp <= _endTime) {
                count++;
            }
        }
        
        // Create array with exact size
        logs = new AuditLog[](count);
        uint256 index = 0;
        
        for (uint256 i = 0; i < auditTrail.length; i++) {
            if (auditTrail[i].timestamp >= _startTime && auditTrail[i].timestamp <= _endTime) {
                logs[index] = auditTrail[i];
                index++;
            }
        }
        
        return logs;
    }
    
    function getLogsByActor(address _actor, uint256 _limit) external view returns (AuditLog[] memory logs) {
        uint256[] memory actorLogIndices = actorLogs[_actor];
        uint256 length = actorLogIndices.length;
        
        if (_limit > 0 && _limit < length) {
            length = _limit;
        }
        
        logs = new AuditLog[](length);
        
        // Get the most recent logs
        for (uint256 i = 0; i < length; i++) {
            uint256 logIndex = actorLogIndices[actorLogIndices.length - 1 - i];
            logs[i] = auditTrail[logIndex];
        }
        
        return logs;
    }
    
    function getLogsByAction(string memory _action, uint256 _limit) external view returns (AuditLog[] memory logs) {
        uint256[] memory actionLogIndices = actionLogs[_action];
        uint256 length = actionLogIndices.length;
        
        if (_limit > 0 && _limit < length) {
            length = _limit;
        }
        
        logs = new AuditLog[](length);
        
        // Get the most recent logs
        for (uint256 i = 0; i < length; i++) {
            uint256 logIndex = actionLogIndices[actionLogIndices.length - 1 - i];
            logs[i] = auditTrail[logIndex];
        }
        
        return logs;
    }
    
    function getTotalLogs() external view returns (uint256) {
        return auditTrail.length;
    }
    
    function getActorLogCount(address _actor) external view returns (uint256) {
        return actorLogs[_actor].length;
    }
    
    function getActionLogCount(string memory _action) external view returns (uint256) {
        return actionLogs[_action].length;
    }
    
    function getDailyLogCount(uint256 _day) external view returns (uint256) {
        return dailyLogs[_day].length;
    }
    
    function searchLogs(
        address _actor,
        string memory _action,
        uint256 _startTime,
        uint256 _endTime
    ) external view returns (AuditLog[] memory logs) {
        // Count matching logs first
        uint256 count = 0;
        for (uint256 i = 0; i < auditTrail.length; i++) {
            AuditLog memory log = auditTrail[i];
            
            bool matchesActor = (_actor == address(0)) || (log.actor == _actor);
            bool matchesAction = (bytes(_action).length == 0) || 
                                (keccak256(bytes(log.action)) == keccak256(bytes(_action)));
            bool matchesTime = (log.timestamp >= _startTime) && (log.timestamp <= _endTime);
            
            if (matchesActor && matchesAction && matchesTime) {
                count++;
            }
        }
        
        // Create array with exact size
        logs = new AuditLog[](count);
        uint256 index = 0;
        
        for (uint256 i = 0; i < auditTrail.length; i++) {
            AuditLog memory log = auditTrail[i];
            
            bool matchesActor = (_actor == address(0)) || (log.actor == _actor);
            bool matchesAction = (bytes(_action).length == 0) || 
                                (keccak256(bytes(log.action)) == keccak256(bytes(_action)));
            bool matchesTime = (log.timestamp >= _startTime) && (log.timestamp <= _endTime);
            
            if (matchesActor && matchesAction && matchesTime) {
                logs[index] = log;
                index++;
            }
        }
        
        return logs;
    }
    
    function generateComplianceReport(
        uint256 _startTime,
        uint256 _endTime
    ) external view returns (
        uint256 totalTransactions,
        uint256 totalPayments,
        uint256 totalEmployeeChanges,
        uint256 totalAdminActions,
        uint256 uniqueActorCount
    ) {
        totalTransactions = 0;
        totalPayments = 0;
        totalEmployeeChanges = 0;
        totalAdminActions = 0;
        uniqueActorCount = 0;
        
        // Track unique actors (simplified for view function)
        address[] memory seenActors = new address[](auditTrail.length);
        
        for (uint256 i = 0; i < auditTrail.length; i++) {
            AuditLog memory log = auditTrail[i];
            
            if (log.timestamp >= _startTime && log.timestamp <= _endTime) {
                totalTransactions++;
                
                // Check action types
                bytes32 actionHash = keccak256(bytes(log.action));
                
                if (actionHash == keccak256("PAYMENT_PROCESSED") || 
                    actionHash == keccak256("BATCH_PAYMENT_PROCESSED")) {
                    totalPayments++;
                } else if (actionHash == keccak256("EMPLOYEE_ADDED") ||
                          actionHash == keccak256("EMPLOYEE_UPDATED") ||
                          actionHash == keccak256("EMPLOYEE_DEACTIVATED")) {
                    totalEmployeeChanges++;
                } else if (actionHash == keccak256("EMERGENCY_PAUSE") ||
                          actionHash == keccak256("EMERGENCY_UNPAUSE") ||
                          actionHash == keccak256("GRANT_ROLE") ||
                          actionHash == keccak256("REVOKE_ROLE")) {
                    totalAdminActions++;
                }
                
                // Count unique actors (simple implementation)
                bool isNewActor = true;
                for (uint256 j = 0; j < uniqueActorCount; j++) {
                    if (seenActors[j] == log.actor) {
                        isNewActor = false;
                        break;
                    }
                }
                if (isNewActor) {
                    seenActors[uniqueActorCount] = log.actor;
                    uniqueActorCount++;
                }
            }
        }
    }
    
    function exportAuditTrail(
        uint256 _startTime,
        uint256 _endTime,
        uint256 _offset,
        uint256 _limit
    ) external view returns (AuditLog[] memory logs, bool hasMore) {
        require(_limit > 0 && _limit <= 100, "Invalid limit (1-100)");
        
        // Count total matching logs
        uint256 totalMatching = 0;
        for (uint256 i = 0; i < auditTrail.length; i++) {
            if (auditTrail[i].timestamp >= _startTime && auditTrail[i].timestamp <= _endTime) {
                totalMatching++;
            }
        }
        
        // Calculate actual return size
        uint256 remaining = totalMatching > _offset ? totalMatching - _offset : 0;
        uint256 returnSize = remaining > _limit ? _limit : remaining;
        hasMore = remaining > _limit;
        
        logs = new AuditLog[](returnSize);
        
        uint256 matchingIndex = 0;
        uint256 returnIndex = 0;
        
        for (uint256 i = 0; i < auditTrail.length && returnIndex < returnSize; i++) {
            if (auditTrail[i].timestamp >= _startTime && auditTrail[i].timestamp <= _endTime) {
                if (matchingIndex >= _offset) {
                    logs[returnIndex] = auditTrail[i];
                    returnIndex++;
                }
                matchingIndex++;
            }
        }
        
        return (logs, hasMore);
    }
}