// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

/**
 * @title ILocalArbitrator
 * @dev Interface for interaction with the LocalArbitrator system
 */
interface ILocalArbitrator {
    function createDispute(uint256 _landlordEstimate, uint256 _renterEstimate) external payable returns (uint256);
    function getArbitrationCost() external view returns (uint256);
}

/**
 * @title HouseRentalAgreement
 * @author Muntasir Jaodun
 * @notice Implements a decentralized rental agreement with local arbitration
 * @dev Optimized for gas efficiency and security with comprehensive state management
 */
contract HouseRentalAgreement is ReentrancyGuard {
    using SafeMath for uint256;
    
    // ===============================
    // Contract state variables
    // ===============================
    
    // Main actors
    address public immutable landlord;
    address public immutable renter;
    
    // Financial parameters
    uint256 public securityDeposit;
    uint256 public baseRent;
    uint256 public rentPeriodInMonths;
    uint256 public currentSecurityDeposit;
    
    // Time tracking
    uint256 public rentStartDate;
    uint256 public currentMonth;
    uint256 public contractEndTime;
    uint256 public lastAction;
    uint256 public timeoutPeriod;
    
    // Dispute handling
    uint256 public damageEstimate;
    uint256 public renterCounterEstimate;
    uint256 public disputeID;
    uint256 public arbitrationCost;
    
    // Additional parameters
    uint256 public dueRent;
    uint256 public cancellationFee; // New: Fee for early cancellation
    uint256 public lateFeePercentage; // New: Late fee percentage
    uint256 public gracePeriod; // New: Grace period for late payments in days
    
    // Efficient state management using uint8 bitmasks instead of multiple booleans
    // Bit positions for state flags:
    // 0: isActive
    // 1: isSecurityDepositPaid
    // 2: disputeRaised
    // 3: rentalPeriodEnded
    // 4: landlordEstimateSet
    // 5: renterCounterEstimateSet
    // 6: isRentDue
    // 7: isPaused (emergency stop)
    uint8 private stateFlags;
    
    // References
    ILocalArbitrator public arbitrator;
    
    // ===============================
    // Data structures
    // ===============================
    
    struct MonthlyRent {
        uint256 baseRent;
        uint256 utilities;
        uint256 due;
        bool paid;
        uint256 paymentDate;
        uint256 dueDate;
        uint256 lateFee;
    }
    
    struct MaintenanceRequest {
        string description;
        uint256 requestDate;
        bool resolved;
        uint256 resolutionDate;
        string resolutionDetails;
        uint256 priority; // 1: Low, 2: Medium, 3: High
    }
    
    // Evidence for disputes
    struct Evidence {
        address submitter;
        string evidenceURI;
        uint256 timestamp;
    }
    
    // ===============================
    // Mappings
    // ===============================
    
    mapping(uint256 => MonthlyRent) public monthlyRents;
    mapping(address => uint256) public pendingWithdrawals;
    mapping(uint256 => MaintenanceRequest) public maintenanceRequests;
    mapping(uint256 => Evidence[]) public disputeEvidence;
    
    // ===============================
    // Events
    // ===============================
    
    // Agreement lifecycle events
    event AgreementCreated(address indexed landlord, address indexed renter, uint256 securityDeposit, uint256 baseRent, uint256 rentPeriodInMonths);
    event AgreementTermsUpdated(uint256 securityDeposit, uint256 baseRent, uint256 rentPeriodInMonths);
    event SecurityDepositPaid(uint256 amount);
    event ContractActivated(uint256 startDate);
    event ContractEnded(uint256 securityDepositReturned, uint256 dueAmountPaid);
    event ContractCancelled(address indexed initiator, uint256 cancellationFee);
    event ContractPaused(address indexed by);
    event ContractResumed(address indexed by);
    
    // Rent related events
    event UtilitiesRecorded(uint256 month, uint256 amount);
    event RentPaid(uint256 month, uint256 amount, uint256 timestamp);
    event RentSkipped(uint256 month, uint256 amount);
    event RentPartiallyPaid(uint256 month, uint256 amount, uint256 remaining);
    event RentLate(uint256 month, uint256 daysLate, uint256 penaltyAmount);
    
    // Maintenance events
    event MaintenanceRequested(uint256 requestId, string description, uint256 priority);
    event MaintenanceResolved(uint256 requestId, string resolution);
    
    // Dispute events
    event DamageEstimateSet(uint256 estimate);
    event CounterEstimateSet(uint256 counterEstimate);
    event DisputeRaised(uint256 disputeID);
    event DisputeResolved(uint256 disputeID, uint256 ruling);
    event EvidenceSubmitted(uint256 disputeID, address submitter, string evidenceURI);
    event EstimateRejected();
    event CounterEstimateAccepted();
    event CounterEstimateRejected();
    
    // Financial events
    event FundsWithdrawn(address indexed to, uint256 amount);
    event WithdrawalRequested(address indexed by, uint256 amount);
    event FundsDistributed(address indexed landlord, uint256 landlordAmount, address indexed renter, uint256 renterAmount);
    
    // ===============================
    // Modifiers
    // ===============================
    
    /**
     * @dev Ensures only the landlord can call the function
     */
    modifier onlyLandlord() {
        require(msg.sender == landlord, "HRA: Caller is not the landlord");
        _;
    }
    
    /**
     * @dev Ensures only the renter can call the function
     */
    modifier onlyRenter() {
        require(msg.sender == renter, "HRA: Caller is not the renter");
        _;
    }
    
    /**
     * @dev Ensures only the landlord or renter can call the function
     */
    modifier onlyParties() {
        require(msg.sender == landlord || msg.sender == renter, "HRA: Caller is not a party to this agreement");
        _;
    }
    
    /**
     * @dev Ensures only active contracts can execute the function
     */
    modifier whenActive() {
        require(isStateActive(0), "HRA: Contract is not active");
        _;
    }
    
    /**
     * @dev Ensures the function can only be called before the contract is active
     */
    modifier beforeActivation() {
        require(!isStateActive(0), "HRA: Contract is already active");
        _;
    }
    
    /**
     * @dev Ensures the rent period has ended
     */
    modifier rentalEnded() {
        require(isStateActive(3), "HRA: Rental period has not ended");
        _;
    }
    
    /**
     * @dev Ensures the contract is not paused (emergency stop)
     */
    modifier whenNotPaused() {
        require(!isStateActive(7), "HRA: Contract is paused");
        _;
    }
    
    /**
     * @dev Ensures only the arbitrator can call the function
     */
    modifier onlyArbitrator() {
        require(msg.sender == address(arbitrator), "HRA: Caller is not the arbitrator");
        _;
    }
    
    /**
     * @dev Check for timeout and allow action by counterparty if timeout has passed
     * @param _stateFlag The state flag to check for timeout
     */
    modifier timeoutBy(uint8 _stateFlag) {
        if (lastAction != 0 && block.timestamp >= lastAction + timeoutPeriod) {
            if (_stateFlag == 4 && msg.sender == renter) {
                _;
            } else if (_stateFlag == 5 && msg.sender == landlord) {
                _;
            } else {
                revert("HRA: Not authorized for timeout action");
            }
        } else {
            if (_stateFlag == 4 && msg.sender == landlord) {
                _;
            } else if (_stateFlag == 5 && msg.sender == renter) {
                _;
            } else {
                revert("HRA: Not authorized for this action");
            }
        }
    }
    
    // ===============================
    // Constructor & initialization
    // ===============================
    
    /**
     * @dev Contract constructor
     * @param _renter Address of the renter
     * @param _arbitratorAddress Address of the local arbitrator contract
     */
    constructor(address _renter, address _arbitratorAddress) {
        require(_renter != address(0), "HRA: Renter address cannot be zero");
        require(_arbitratorAddress != address(0), "HRA: Arbitrator address cannot be zero");
        require(_renter != msg.sender, "HRA: Landlord and renter must be different");
        
        landlord = msg.sender;
        renter = _renter;
        arbitrator = ILocalArbitrator(_arbitratorAddress);
        
        // Initialize state
        stateFlags = 0;
        timeoutPeriod = 7 days;
        gracePeriod = 3 days;
        lateFeePercentage = 5; // 5% late fee
        cancellationFee = 10; // 10% cancellation fee
    }
    
    /**
     * @dev Sets the initial terms of the rental agreement
     * @param _securityDeposit The security deposit amount in wei
     * @param _baseRent The monthly base rent amount in wei
     * @param _rentPeriodInMonths The duration of the rental period in months
     * @param _cancellationFeePercentage The fee percentage for early cancellation (0-100)
     * @param _lateFeePercentage The fee percentage for late payments (0-100)
     * @param _gracePeriodDays The grace period for late payments in days
     */
    function setAgreementTerms(
        uint256 _securityDeposit, 
        uint256 _baseRent, 
        uint256 _rentPeriodInMonths,
        uint256 _cancellationFeePercentage,
        uint256 _lateFeePercentage,
        uint256 _gracePeriodDays
    ) 
        external 
        onlyLandlord 
        beforeActivation 
    {
        require(_securityDeposit > 0, "HRA: Security deposit must be positive");
        require(_baseRent > 0, "HRA: Base rent must be positive");
        require(_rentPeriodInMonths > 0, "HRA: Rent period must be positive");
        require(_cancellationFeePercentage <= 100, "HRA: Cancellation fee cannot exceed 100%");
        require(_lateFeePercentage <= 100, "HRA: Late fee cannot exceed 100%");
        
        securityDeposit = _securityDeposit;
        baseRent = _baseRent;
        rentPeriodInMonths = _rentPeriodInMonths;
        cancellationFee = _cancellationFeePercentage;
        lateFeePercentage = _lateFeePercentage;
        gracePeriod = _gracePeriodDays * 1 days;
        
        emit AgreementTermsUpdated(_securityDeposit, _baseRent, _rentPeriodInMonths);
    }
    
    /**
     * @dev Allows the renter to pay the security deposit
     */
    function paySecurityDeposit() 
        external 
        payable 
        onlyRenter 
        beforeActivation 
    {
        require(securityDeposit > 0, "HRA: Agreement terms not set");
        require(msg.value == securityDeposit, "HRA: Incorrect security deposit amount");
        
        setStateActive(1, true); // Security deposit paid
        currentSecurityDeposit = securityDeposit;
        
        emit SecurityDepositPaid(msg.value);
        
        // Automatically activate the contract
        setStateActive(0, true); // Set contract as active
        rentStartDate = block.timestamp;
        currentMonth = 1;
        contractEndTime = block.timestamp + (rentPeriodInMonths * 30 days);
        
        emit ContractActivated(rentStartDate);
    }
    
    // ===============================
    // Rent management
    // ===============================
    
    /**
     * @dev Records utilities for the current month
     * @param _utilities The utility cost for the current month
     */
    function recordUtilities(uint256 _utilities) 
        external 
        onlyLandlord 
        whenActive 
        whenNotPaused 
    {
        require(currentMonth <= rentPeriodInMonths, "HRA: Rent period has ended");
        
        MonthlyRent storage currentRent = monthlyRents[currentMonth];
        currentRent.utilities = _utilities;
        currentRent.baseRent = baseRent;
        currentRent.dueDate = block.timestamp + 10 days; // Due in 10 days after utilities recorded
        
        emit UtilitiesRecorded(currentMonth, _utilities);
    }
    
    /**
     * @dev Allows the renter to pay the full rent for the current month
     */
    function payRent() 
        external 
        payable 
        onlyRenter 
        whenActive 
        whenNotPaused 
        nonReentrant 
    {
        require(currentMonth <= rentPeriodInMonths, "HRA: Rent period has ended");
        
        MonthlyRent storage currentRent = monthlyRents[currentMonth];
        require(!currentRent.paid, "HRA: Rent for this month has already been paid");
        require(currentRent.utilities > 0, "HRA: Utilities for this month have not been recorded");
        
        uint256 lateFee = 0;
        // Check if payment is late and calculate late fee if applicable
        if (currentRent.dueDate < block.timestamp && block.timestamp > currentRent.dueDate + gracePeriod) {
            uint256 daysLate = (block.timestamp - currentRent.dueDate - gracePeriod) / 1 days;
            lateFee = baseRent.mul(lateFeePercentage).div(100);
            currentRent.lateFee = lateFee;
            emit RentLate(currentMonth, daysLate, lateFee);
        }
        
        uint256 totalRent = currentRent.baseRent.add(currentRent.utilities).add(dueRent).add(lateFee);
        require(msg.value == totalRent, "HRA: Incorrect rent amount");
        
        currentRent.paid = true;
        currentRent.paymentDate = block.timestamp;
        dueRent = 0;
        
        emit RentPaid(currentMonth, totalRent, block.timestamp);
        
        // Add to pending withdrawals for landlord
        pendingWithdrawals[landlord] = pendingWithdrawals[landlord].add(totalRent);
        emit WithdrawalRequested(landlord, totalRent);
        
        // Move to next month or end rental period
        if (currentMonth == rentPeriodInMonths) {
            setStateActive(3, true); // Rental period ended
        } else {
            currentMonth = currentMonth.add(1);
        }
    }
    
    /**
     * @dev Allows the renter to make a partial rent payment
     * @param _partialAmount The partial payment amount
     */
    function payPartialRent(uint256 _partialAmount) 
        external 
        payable 
        onlyRenter 
        whenActive 
        whenNotPaused 
        nonReentrant 
    {
        require(currentMonth <= rentPeriodInMonths, "HRA: Rent period has ended");
        
        MonthlyRent storage currentRent = monthlyRents[currentMonth];
        require(!currentRent.paid, "HRA: Rent for this month has already been paid");
        require(currentRent.utilities > 0, "HRA: Utilities for this month have not been recorded");
        
        uint256 lateFee = 0;
        // Check if payment is late and calculate late fee if applicable
        if (currentRent.dueDate < block.timestamp && block.timestamp > currentRent.dueDate + gracePeriod) {
            uint256 daysLate = (block.timestamp - currentRent.dueDate - gracePeriod) / 1 days;
            lateFee = baseRent.mul(lateFeePercentage).div(100);
            currentRent.lateFee = lateFee;
            emit RentLate(currentMonth, daysLate, lateFee);
        }
        
        uint256 totalRent = currentRent.baseRent.add(currentRent.utilities).add(dueRent).add(lateFee);
        require(msg.value == _partialAmount, "HRA: Incorrect payment amount");
        require(_partialAmount < totalRent, "HRA: Use payRent for full payment");
        require(_partialAmount > 0, "HRA: Payment must be greater than zero");
        
        // Update due rent
        dueRent = totalRent.sub(_partialAmount);
        
        emit RentPartiallyPaid(currentMonth, _partialAmount, dueRent);
        
        // Add to pending withdrawals for landlord
        pendingWithdrawals[landlord] = pendingWithdrawals[landlord].add(_partialAmount);
        emit WithdrawalRequested(landlord, _partialAmount);
    }
    
    /**
     * @dev Allows the renter to skip the current month's rent payment
     * @notice The skipped amount is added to future due rent
     */
    function skipRentPayment() 
        external 
        onlyRenter 
        whenActive 
        whenNotPaused 
    {
        require(currentMonth < rentPeriodInMonths, "HRA: Cannot skip rent for the last month");
        
        MonthlyRent storage currentRent = monthlyRents[currentMonth];
        require(!currentRent.paid, "HRA: Rent for this month has already been paid");
        require(currentRent.utilities > 0, "HRA: Utilities for this month have not been recorded");
        
        uint256 lateFee = 0;
        // Check if payment is late and calculate late fee if applicable
        if (currentRent.dueDate < block.timestamp && block.timestamp > currentRent.dueDate + gracePeriod) {
            uint256 daysLate = (block.timestamp - currentRent.dueDate - gracePeriod) / 1 days;
            lateFee = baseRent.mul(lateFeePercentage).div(100);
            currentRent.lateFee = lateFee;
            emit RentLate(currentMonth, daysLate, lateFee);
        }
        
        uint256 skippedAmount = currentRent.baseRent.add(currentRent.utilities).add(lateFee);
        dueRent = dueRent.add(skippedAmount);
        
        emit RentSkipped(currentMonth, skippedAmount);
        
        // Move to next month
        currentMonth = currentMonth.add(1);
        
        // Check if we've reached the final month
        if (currentMonth == rentPeriodInMonths) {
            setStateActive(3, true); // Mark rental period as ending
        }
    }
    
    // ===============================
    // Maintenance management
    // ===============================
    
    /**
     * @dev Allows the renter to submit a maintenance request
     * @param _description Description of the maintenance issue
     * @param _priority Priority level (1: Low, 2: Medium, 3: High)
     * @return requestId The ID of the created maintenance request
     */
    function requestMaintenance(string calldata _description, uint256 _priority) 
        external 
        onlyRenter 
        whenActive 
        whenNotPaused 
        returns (uint256 requestId) 
    {
        require(bytes(_description).length > 0, "HRA: Description cannot be empty");
        require(_priority >= 1 && _priority <= 3, "HRA: Invalid priority level");
        
        // Generate ID based on timestamp and request count
        requestId = uint256(keccak256(abi.encodePacked(block.timestamp, address(this), _description))) % 1000000;
        
        maintenanceRequests[requestId] = MaintenanceRequest({
            description: _description,
            requestDate: block.timestamp,
            resolved: false,
            resolutionDate: 0,
            resolutionDetails: "",
            priority: _priority
        });
        
        emit MaintenanceRequested(requestId, _description, _priority);
        return requestId;
    }
    
    /**
     * @dev Allows the landlord to resolve a maintenance request
     * @param _requestId The ID of the maintenance request
     * @param _resolutionDetails Details of how the issue was resolved
     */
    function resolveMaintenance(uint256 _requestId, string calldata _resolutionDetails) 
        external 
        onlyLandlord 
        whenActive 
        whenNotPaused 
    {
        MaintenanceRequest storage request = maintenanceRequests[_requestId];
        require(request.requestDate > 0, "HRA: Maintenance request does not exist");
        require(!request.resolved, "HRA: Maintenance request already resolved");
        
        request.resolved = true;
        request.resolutionDate = block.timestamp;
        request.resolutionDetails = _resolutionDetails;
        
        emit MaintenanceResolved(_requestId, _resolutionDetails);
    }
    
    // ===============================
    // End of rental period handling
    // ===============================
    
    /**
     * @dev Allows the landlord to set a damage estimate at the end of rental
     * @param _damageEstimate Estimated cost of damages
     */
    function setDamageEstimate(uint256 _damageEstimate) 
        external 
        onlyLandlord 
        rentalEnded 
        whenActive 
        timeoutBy(4)
    {
        require(!isStateActive(4), "HRA: Damage estimate already set");
        
        damageEstimate = _damageEstimate;
        setStateActive(4, true); // Landlord estimate set
        lastAction = block.timestamp;
        
        emit DamageEstimateSet(_damageEstimate);
    }
    
    /**
     * @dev Allows the renter to accept the landlord's damage estimate
     */
    function acceptLandlordEstimate() 
        external 
        onlyRenter 
        whenActive 
        nonReentrant 
    {
        require(isStateActive(4), "HRA: Landlord must set damage estimate first");
        
        uint256 damageAmount = damageEstimate < currentSecurityDeposit ? damageEstimate : currentSecurityDeposit;
        
        pendingWithdrawals[landlord] = pendingWithdrawals[landlord].add(damageAmount);
        pendingWithdrawals[renter] = pendingWithdrawals[renter].add(currentSecurityDeposit.sub(damageAmount));
        
        emit WithdrawalRequested(landlord, damageAmount);
        emit WithdrawalRequested(renter, currentSecurityDeposit.sub(damageAmount));
        
        // End contract
        endContract();
    }
    
    /**
     * @dev Allows the renter to reject the landlord's damage estimate
     */
    function rejectLandlordEstimate() 
        external 
        onlyRenter 
        whenActive 
    {
        require(isStateActive(4), "HRA: Landlord must set damage estimate first");
        
        emit EstimateRejected();
    }
    
    /**
     * @dev Allows the renter to set a counter-estimate for damages
     * @param _renterCounterEstimate Renter's counter estimate of damage costs
     */
    function setRenterCounterEstimate(uint256 _renterCounterEstimate) 
        external 
        onlyRenter 
        whenActive 
        timeoutBy(5)
    {
        require(isStateActive(4), "HRA: Landlord must set damage estimate first");
        require(!isStateActive(5), "HRA: Counter estimate already set");
        
        renterCounterEstimate = _renterCounterEstimate;
        setStateActive(5, true); // Renter counter estimate set
        lastAction = block.timestamp;
        
        emit CounterEstimateSet(_renterCounterEstimate);
    }
    
    /**
     * @dev Allows the landlord to accept the renter's counter-estimate
     */
    function acceptRenterCounterEstimate() 
        external 
        onlyLandlord 
        whenActive 
        nonReentrant 
    {
        require(isStateActive(5), "HRA: Renter must set counter estimate first");
        
        uint256 damageAmount = renterCounterEstimate < currentSecurityDeposit ? renterCounterEstimate : currentSecurityDeposit;
        
        pendingWithdrawals[landlord] = pendingWithdrawals[landlord].add(damageAmount);
        pendingWithdrawals[renter] = pendingWithdrawals[renter].add(currentSecurityDeposit.sub(damageAmount));
        
        emit WithdrawalRequested(landlord, damageAmount);
        emit WithdrawalRequested(renter, currentSecurityDeposit.sub(damageAmount));
        
        emit CounterEstimateAccepted();
        
        // End contract
        endContract();
    }
    
    /**
     * @dev Allows the landlord to reject the renter's counter-estimate and initiate arbitration
     */
    function rejectRenterCounterEstimate() 
        external 
        onlyLandlord 
        whenActive 
        nonReentrant 
    {
        require(isStateActive(5), "HRA: Renter must set counter estimate first");
        
        // Calculate arbitration cost
        arbitrationCost = arbitrator.getArbitrationCost();
        require(currentSecurityDeposit >= arbitrationCost, "HRA: Security deposit insufficient for arbitration");
        
        currentSecurityDeposit = currentSecurityDeposit.sub(arbitrationCost);
        
        // Create dispute with local arbitrator
        disputeID = arbitrator.createDispute{value: arbitrationCost}(damageEstimate, renterCounterEstimate);
        setStateActive(2, true); // Dispute raised
        
        emit DisputeRaised(disputeID);
        emit CounterEstimateRejected();
    }
    
    /**
     * @dev Allows parties to submit evidence for a dispute
     * @param _disputeID The ID of the dispute
     * @param _evidenceURI URI pointing to the evidence
     */
    function submitEvidence(uint256 _disputeID, string calldata _evidenceURI) 
        external 
        onlyParties
        whenActive 
    {
        require(isStateActive(2), "HRA: No active dispute");
        require(_disputeID == disputeID, "HRA: Invalid dispute ID");
        require(bytes(_evidenceURI).length > 0, "HRA: Evidence URI cannot be empty");
        
        disputeEvidence[_disputeID].push(Evidence({
            submitter: msg.sender,
            evidenceURI: _evidenceURI,
            timestamp: block.timestamp
        }));
        
        emit EvidenceSubmitted(_disputeID, msg.sender, _evidenceURI);
    }
    
    /**
     * @dev Callback function from local arbitrator to execute a ruling
     * @param _disputeID The ID of the dispute
     * @param _ruling The arbitrator's ruling (1: landlord, 2: renter)
     * @param _refundAmount The amount to refund from arbitration fee
     */
    function executeRuling(uint256 _disputeID, uint256 _ruling, uint256 _refundAmount) 
        external 
        onlyArbitrator 
        nonReentrant 
    {
        require(isStateActive(2), "HRA: No dispute to rule on");
        require(_disputeID == disputeID, "HRA: Invalid dispute ID");
        
        uint256 damageAmount;
        
        if (_ruling == 1) {
            // Ruling in favor of the landlord
            damageAmount = damageEstimate < currentSecurityDeposit ? damageEstimate : currentSecurityDeposit;
        } else if (_ruling == 2) {
            // Ruling in favor of the renter
            damageAmount = renterCounterEstimate < currentSecurityDeposit ? renterCounterEstimate : currentSecurityDeposit;
        } else {
            // Split the deposit if the ruling is unclear
            damageAmount = currentSecurityDeposit.div(2);
        }
        
        // Distribute the current security deposit
        pendingWithdrawals[landlord] = pendingWithdrawals[landlord].add(damageAmount);
        pendingWithdrawals[renter] = pendingWithdrawals[renter].add(currentSecurityDeposit.sub(damageAmount));
        
        // Refund part of the arbitration cost to the winning party
        if (_refundAmount > 0) {
            if (_ruling == 1) {
                pendingWithdrawals[landlord] = pendingWithdrawals[landlord].add(_refundAmount);
            } else if (_ruling == 2) {
                pendingWithdrawals[renter] = pendingWithdrawals[renter].add(_refundAmount);
            } else {
                // If no clear winner, split the refund
                uint256 halfRefund = _refundAmount.div(2);
                pendingWithdrawals[landlord] = pendingWithdrawals[landlord].add(halfRefund);
                pendingWithdrawals[renter] = pendingWithdrawals[renter].add(_refundAmount.sub(halfRefund));
            }
        }
        
        emit FundsDistributed(landlord, pendingWithdrawals[landlord], renter, pendingWithdrawals[renter]);
        emit DisputeResolved(_disputeID, _ruling);
        
        // Reset dispute state and end contract
        setStateActive(2, false);
        endContract();
