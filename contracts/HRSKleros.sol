// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

/**
 * @title IArbitrator
 * @dev Interface for interaction with the Kleros arbitration system
 */
interface IArbitrator {
    function createDispute(uint256 _choices, bytes calldata _extraData) external payable returns (uint256 disputeID);
    function arbitrationCost(bytes calldata _extraData) external view returns (uint256);
}

/**
 * @title IArbitrable
 * @dev Interface for contracts that can be arbitrated
 */
interface IArbitrable {
    function rule(uint256 _disputeID, uint256 _ruling) external;
}

/**
 * @title HouseRentalAgreement
 * @author Muntasir Jaodun
 * @notice Implements a decentralized rental agreement with Kleros arbitration
 * @dev Optimized for gas efficiency and security with comprehensive state management
 */
contract HouseRentalAgreement is IArbitrable, ReentrancyGuard {
    using SafeMath for uint256;
    
    // ===============================
    // Contract state variables
    // ===============================
    
    // Main actors
    address public immutable landlord;
    address public immutable renter;
    address public immutable klerosArbitrator;
    
    // Financial parameters
    uint256 public securityDeposit;
    uint256 public baseRent;
    uint256 public rentPeriodInMonths;
    uint256 public currentSecurityDeposit;
    
    // Time tracking
    uint256 public rentStartDate;
    uint256 public currentMonth;
    uint256 public contractEndTime;
    
    // Dispute handling
    uint256 public damageEstimate;
    uint256 public renterCounterEstimate;
    uint256 public disputeID;
    uint256 public arbitrationCost;
    uint256 public lastAction;
    uint256 public timeoutPeriod;
    
    // Additional parameters
    uint256 public dueRent;
    uint256 public cancellationFee; // New: Fee for early cancellation
    
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
    IArbitrator public kleros;
    
    // ===============================
    // Data structures
    // ===============================
    
    struct MonthlyRent {
        uint256 baseRent;
        uint256 utilities;
        uint256 due;
        bool paid;
        uint256 paymentDate;
    }
    
    struct MaintenanceRequest {
        string description;
        uint256 requestDate;
        bool resolved;
        uint256 resolutionDate;
        string resolutionDetails;
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
    event MaintenanceRequested(uint256 requestId, string description);
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
     * @dev Ensures only the Kleros arbitrator can call the function
     */
    modifier onlyArbitrator() {
        require(msg.sender == address(kleros), "HRA: Caller is not the arbitrator");
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
     * @param _klerosAddress Address of the Kleros arbitrator contract
     */
    constructor(address _renter, address _klerosAddress) {
        require(_renter != address(0), "HRA: Renter address cannot be zero");
        require(_klerosAddress != address(0), "HRA: Kleros address cannot be zero");
        require(_renter != msg.sender, "HRA: Landlord and renter must be different");
        
        landlord = msg.sender;
        renter = _renter;
        klerosArbitrator = _klerosAddress;
        kleros = IArbitrator(_klerosAddress);
        
        // Initialize state
        stateFlags = 0;
        timeoutPeriod = 7 days;
        
        // Default cancellation fee (10% of security deposit)
        cancellationFee = 10;
    }
    
    /**
     * @dev Sets the initial terms of the rental agreement
     * @param _securityDeposit The security deposit amount in wei
     * @param _baseRent The monthly base rent amount in wei
     * @param _rentPeriodInMonths The duration of the rental period in months
     * @param _cancellationFeePercentage The fee percentage for early cancellation (0-100)
     */
    function setAgreementTerms(
        uint256 _securityDeposit, 
        uint256 _baseRent, 
        uint256 _rentPeriodInMonths,
        uint256 _cancellationFeePercentage
    ) 
        external 
        onlyLandlord 
        beforeActivation 
    {
        require(_securityDeposit > 0, "HRA: Security deposit must be positive");
        require(_baseRent > 0, "HRA: Base rent must be positive");
        require(_rentPeriodInMonths > 0, "HRA: Rent period must be positive");
        require(_cancellationFeePercentage <= 100, "HRA: Cancellation fee cannot exceed 100%");
        
        securityDeposit = _securityDeposit;
        baseRent = _baseRent;
        rentPeriodInMonths = _rentPeriodInMonths;
        cancellationFee = _cancellationFeePercentage;
        
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
    }
    
    /**
     * @dev Activates the contract after security deposit is paid
     */
    function activateContract() 
        external 
        onlyLandlord 
        beforeActivation 
    {
        require(isStateActive(1), "HRA: Security deposit must be paid first");
        
        setStateActive(0, true); // Contract active
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
        
        uint256 totalRent = currentRent.baseRent.add(currentRent.utilities).add(dueRent);
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
        
        uint256 totalRent = currentRent.baseRent.add(currentRent.utilities).add(dueRent);
        require(msg.value == _partialAmount, "HRA: Incorrect payment amount");
        require(_partialAmount < totalRent, "HRA: Use payRent for full payment");
        
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
        require(currentMonth <= rentPeriodInMonths, "HRA: Rent period has ended");
        
        MonthlyRent storage currentRent = monthlyRents[currentMonth];
        require(!currentRent.paid, "HRA: Rent for this month has already been paid");
        require(currentRent.utilities > 0, "HRA: Utilities for this month have not been recorded");
        
        uint256 skippedAmount = currentRent.baseRent.add(currentRent.utilities);
        dueRent = dueRent.add(skippedAmount);
        
        emit RentSkipped(currentMonth, skippedAmount);
        
        // Move to next month or end rental period
        if (currentMonth == rentPeriodInMonths) {
            setStateActive(3, true); // Rental period ended
        } else {
            currentMonth = currentMonth.add(1);
        }
    }
    
    // ===============================
    // Maintenance management
    // ===============================
    
    /**
     * @dev Allows the renter to submit a maintenance request
     * @param _description Description of the maintenance issue
     * @return requestId The ID of the created maintenance request
     */
    function requestMaintenance(string calldata _description) 
        external 
        onlyRenter 
        whenActive 
        whenNotPaused 
        returns (uint256 requestId) 
    {
        require(bytes(_description).length > 0, "HRA: Description cannot be empty");
        
        // Generate ID based on timestamp and request count
        requestId = uint256(keccak256(abi.encodePacked(block.timestamp, address(this), _description))) % 1000000;
        
        maintenanceRequests[requestId] = MaintenanceRequest({
            description: _description,
            requestDate: block.timestamp,
            resolved: false,
            resolutionDate: 0,
            resolutionDetails: ""
        });
        
        emit MaintenanceRequested(requestId, _description);
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
        setStateActive(0, false); // Deactivate contract
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
        setStateActive(0, false); // Deactivate contract
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
        arbitrationCost = kleros.arbitrationCost("");
        require(currentSecurityDeposit >= arbitrationCost, "HRA: Security deposit insufficient for arbitration");
        
        currentSecurityDeposit = currentSecurityDeposit.sub(arbitrationCost);
        
        // Create dispute in Kleros
        disputeID = kleros.createDispute{value: arbitrationCost}(2, "");
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
        whenActive 
    {
        require(msg.sender == landlord || msg.sender == renter, "HRA: Only landlord or renter can submit evidence");
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
     * @dev Callback function from Kleros to rule on a dispute
     * @param _disputeID The ID of the dispute
     * @param _ruling The ruling from the arbitrator (1: landlord, 2: renter)
     */
    function rule(uint256 _disputeID, uint256 _ruling) 
        external 
        override 
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
        
        emit WithdrawalRequested(landlord, damageAmount);
        emit WithdrawalRequested(renter, currentSecurityDeposit.sub(damageAmount));
        
        // Reset dispute state and deactivate contract
        setStateActive(2, false); // Dispute resolved
        setStateActive(0, false); // Deactivate contract
        
        emit DisputeResolved(_disputeID, _ruling);
    }
    
    // ===============================
    // Financial operations
    // ===============================
    
    /**
     * @dev Allows parties to withdraw their pending funds
     */
    function withdraw() 
        external 
        nonReentrant 
    {
        uint256 amount = pendingWithdrawals[msg.sender];
        require(amount > 0, "HRA: No funds to withdraw");
        
        // Update state before transfer to prevent reentrancy
        pendingWithdrawals[msg.sender] = 0;
        
        // Transfer funds
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "HRA: Transfer failed");
        
        emit FundsWithdrawn(msg.sender, amount);
    }
    
    /**
     * @dev Allows early cancellation of the contract
     * @notice Cancellation can only happen before the rental period ends
     */
    function cancelContract() 
        external 
        whenActive 
        nonReentrant 
    {
        require(!isStateActive(3), "HRA: Rental period has already ended");
        require(msg.sender == landlord || msg.sender == renter, "HRA: Only landlord or renter can cancel");
        
        uint256 fee = securityDeposit.mul(cancellationFee).div(100);
        uint256 refund = currentSecurityDeposit.sub(fee);
        
        if (msg.sender == landlord) {
            // Landlord cancels: pays fee to renter, renter gets deposit back
            require(address(this).balance >= fee, "HRA: Insufficient balance for cancellation");
            pendingWithdrawals[renter] = pendingWithdrawals[renter].add(currentSecurityDeposit.add(fee));
        } else {
            // Renter cancels: pays fee to landlord, gets deposit back minus fee
            pendingWithdrawals[landlord] = pendingWithdrawals[landlord].add(fee);
            pendingWithdrawals[renter] = pendingWithdrawals[renter].add(refund);
        }
        
        // Deactivate contract
        setStateActive(0, false);
        
        emit ContractCancelled(msg.sender, fee);
    }
    
    // ===============================
    // Emergency controls
    // ===============================
    
    /**
     * @dev Allows the landlord to pause the contract in emergency
     */
    function pauseContract() 
        external 
        onlyLandlord 
        whenActive 
    {
        setStateActive(7, true); // Set paused flag
        emit ContractPaused(msg.sender);
    }
    
    /**
     * @dev Allows the landlord to resume the contract
     */
    function resumeContract() 
        external 
        onlyLandlord 
        whenActive 
    {
        require(isStateActive(7), "HRA: Contract is not paused");
        setStateActive(7, false); // Unset paused flag
        emit ContractResumed(msg.sender);
    }
    
    // ===============================
    // Utility functions
    // ===============================
    
    /**
     * @dev Sets a state flag to active or inactive
     * @param _flag The flag bit position
     * @param _active Whether to activate or deactivate the flag
     */
    function setStateActive(uint8 _flag, bool _active) private {
        if (_active) {
            stateFlags |= (1 << _flag);
        } else {
            stateFlags &= ~(1 << _flag);
        }
    }
    
    /**
     * @dev Checks if a state flag is active
     * @param _flag The flag bit position
     * @return bool Whether the flag is active
     */
    function isStateActive(uint8 _flag) private view returns (bool) {
        return (stateFlags & (1 << _flag)) != 0;
    }
    
    /**
     * @dev Returns whether the contract is active
     * @return bool Contract active state
     */
    function isContractActive() external view returns (bool) {
        return isStateActive(0);
    }
    
    /**
     * @dev Returns whether security deposit is paid
     * @return bool Security deposit payment state
     */
    function isSecurityDepositPaid() external view returns (bool) {
        return isStateActive(1);
    }
    
    /**
     * @dev Returns whether there is an active dispute
     * @return bool Dispute state
     */
    function isDisputeActive() external view returns (bool) {
        return isStateActive(2);
    }
    
    /**
     * @dev Returns whether the rental period has ended
     * @return bool Rental period end state
     */
    public function isRentalPeriodEnded() external view returns (bool) {
        return isStateActive(3);
    }
    
    /**
     * @dev Returns the current security deposit amount
     * @return uint256 Current security deposit
     */
    function getCurrentSecurityDeposit() public view returns (uint256) {
        return currentSecurityDeposit;
    }
    
    /**
     * @dev Returns the current arbitration cost from Kleros
     * @return uint256 Arbitration cost
     */
    function getArbitrationCost() public view returns (uint256) {
        return kleros.arbitrationCost("");
    }
    
    /**
     * @dev Returns the contract balance
     * @return uint256 Contract balance
     */
    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }
    
    /**
     * @dev Returns the payment status for a specific month
     * @param _month The month to check
     * @return bool Whether rent is paid for that month
     */
    function isRentPaid(uint256 _month) external view returns (bool) {
        require(_month > 0 && _month <= rentPeriodInMonths, "HRA: Invalid month");
        return monthlyRents[_month].paid;
    }
    
    /**
     * @dev Returns all evidence for a dispute
     * @param _disputeID The dispute ID
     * @return Evidence[] Array of evidence
     */
    function getDisputeEvidence(uint256 _disputeID) external view returns (
        address[] memory submitters,
        string[] memory evidenceURIs,
        uint256[] memory timestamps
    ) {
        require(_disputeID == disputeID, "HRA: Invalid dispute ID");
        
        Evidence[] storage evidence = disputeEvidence[_disputeID];
        uint256 count = evidence.length;
        
        submitters = new address[](count);
        evidenceURIs = new string[](count);
        timestamps = new uint256[](count);
        
        for (uint256 i = 0; i < count; i++) {
            submitters[i] = evidence[i].submitter;
            evidenceURIs[i] = evidence[i].evidenceURI;
            timestamps[i] = evidence[i].timestamp;
        }
        
        return (submitters, evidenceURIs, timestamps);
    }
    
    /**
     * @dev Fallback function to receive ETH
     */
    receive() external payable {}
}
