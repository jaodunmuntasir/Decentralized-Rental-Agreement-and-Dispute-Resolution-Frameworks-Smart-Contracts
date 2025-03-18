// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IArbitrator {
    function createDispute(uint256 _choices, bytes calldata _extraData) external payable returns (uint256 disputeID);
    function arbitrationCost(bytes calldata _extraData) external view returns (uint256);
}

interface IArbitrable {
    function rule(uint256 _disputeID, uint256 _ruling) external;
}

contract HouseRentalAgreement is IArbitrable {
    address public landlord;
    address public renter;
    uint256 public securityDeposit;
    uint256 public baseRent;
    uint256 public rentPeriodInMonths;
    uint256 public rentStartDate;
    uint256 public currentMonth;
    uint256 public dueRent;
    uint256 public damageEstimate;
    uint256 public renterCounterEstimate;
    uint256 public disputeID;
    uint256 public currentSecurityDeposit;
    uint256 public arbitrationCost;
    bool public isActive;
    bool public isSecurityDepositPaid;
    bool public disputeRaised;
    bool public landlordAccepted;
    bool public renterAccepted;
    bool public rentalPeriodEnded;
    bool public landlordEstimateSet;
    bool public renterCounterEstimateSet;

    IArbitrator public kleros;

    struct MonthlyRent {
        uint256 baseRent;
        uint256 utilities;
        uint256 due;
        bool paid;
    }

    mapping(uint256 => MonthlyRent) public monthlyRents;
    mapping(address => uint256) public pendingWithdrawals;

    event AgreementTermsSet(uint256 securityDeposit, uint256 baseRent, uint256 rentPeriodInMonths);
    event SecurityDepositPaid(uint256 amount);
    event UtilitiesRecorded(uint256 month, uint256 amount);
    event RentPaid(uint256 month, uint256 amount);
    event RentSkipped(uint256 month, uint256 amount);
    event RentTransferred(uint256 month, uint256 amount);
    event ContractEnded(uint256 securityDepositReturned, uint256 dueAmountPaid);
    event DamageEstimateSet(uint256 estimate);
    event CounterEstimateSet(uint256 counterEstimate);
    event DisputeRaised(uint256 disputeID);
    event DisputeResolved(uint256 disputeID, uint256 ruling);
    event EstimateRejected();
    event CounterEstimateAccepted();
    event CounterEstimateRejected();
    event FundsTransferred(address indexed to, uint256 amount);
    event WithdrawalRequested(address indexed by, uint256 amount);

    constructor(address _renter, address _klerosAddress) {
        landlord = msg.sender;
        renter = _renter;
        kleros = IArbitrator(_klerosAddress);
        isActive = false;
        isSecurityDepositPaid = false;
        disputeRaised = false;
        currentSecurityDeposit = securityDeposit;
    }

    function setAgreementTerms(uint256 _securityDeposit, uint256 _baseRent, uint256 _rentPeriodInMonths) external {
        require(msg.sender == landlord, "Only landlord can set agreement terms");
        require(!isActive, "Contract is already active");
        securityDeposit = _securityDeposit;
        baseRent = _baseRent;
        rentPeriodInMonths = _rentPeriodInMonths;
        emit AgreementTermsSet(_securityDeposit, _baseRent, _rentPeriodInMonths);
    }

    function paySecurityDeposit() external payable {
        require(msg.sender == renter, "Only renter can pay security deposit");
        require(!isActive, "Contract is already active");
        require(msg.value == securityDeposit, "Incorrect security deposit amount");
        isSecurityDepositPaid = true;
        emit SecurityDepositPaid(msg.value);
    }

    function activateContract() external {
        require(msg.sender == landlord, "Only landlord can activate the contract");
        require(isSecurityDepositPaid, "Security deposit must be paid first");
        require(!isActive, "Contract is already active");
        isActive = true;
        rentStartDate = block.timestamp;
        currentMonth = 1;
    }

    function initializeCurrentSecurityDeposit() external {
        require(msg.sender == landlord, "Only landlord can initialize current security deposit");
        require(isActive, "Contract must be active");
        require(currentSecurityDeposit == 0, "Current security deposit already initialized");
        currentSecurityDeposit = securityDeposit;
    }

    function recordUtilities(uint256 _utilities) external {
        require(msg.sender == landlord, "Only landlord can record utilities");
        require(isActive, "Contract is not active");
        require(currentMonth <= rentPeriodInMonths, "Rent period has ended");
        monthlyRents[currentMonth].utilities = _utilities;
        monthlyRents[currentMonth].baseRent = baseRent;
        emit UtilitiesRecorded(currentMonth, _utilities);
    }

    function payRent() external payable {
        require(msg.sender == renter, "Only renter can pay rent");
        require(isActive, "Contract is not active");
        require(currentMonth <= rentPeriodInMonths, "Rent period has ended");

        MonthlyRent storage currentRent = monthlyRents[currentMonth];
        require(!currentRent.paid, "Rent for this month has already been paid");
        require(currentRent.utilities > 0, "Utilities for this month have not been recorded");

        uint256 totalRent = currentRent.baseRent + currentRent.utilities + dueRent;
        require(msg.value == totalRent, "Incorrect rent amount");

        currentRent.paid = true;
        dueRent = 0;

        emit RentPaid(currentMonth, totalRent);

        // Instead of transferring, add to pending withdrawals
        pendingWithdrawals[landlord] += totalRent;
        emit WithdrawalRequested(landlord, totalRent);

        if (currentMonth == rentPeriodInMonths) {
            rentalPeriodEnded = true;  // Set the flag instead of ending the contract
        } else {
            currentMonth++;
        }
    }

    function skipRentPayment() external {
        require(msg.sender == renter, "Only renter can skip rent payment");
        require(isActive, "Contract is not active");
        require(currentMonth <= rentPeriodInMonths, "Rent period has ended");

        MonthlyRent storage currentRent = monthlyRents[currentMonth];
        require(!currentRent.paid, "Rent for this month has already been paid");
        require(currentRent.utilities > 0, "Utilities for this month have not been recorded");

        uint256 skippedAmount = currentRent.baseRent + currentRent.utilities;
        dueRent += skippedAmount;

        emit RentSkipped(currentMonth, skippedAmount);

        if (currentMonth == rentPeriodInMonths) {
            endContract();
        } else {
            currentMonth++;
        }
    }

    function setDamageEstimate(uint256 _damageEstimate) external {
        require(msg.sender == landlord, "Only landlord can set the damage estimate");
        require(rentalPeriodEnded, "Rent period has not ended yet");
        require(!landlordEstimateSet, "Damage estimate already set");
        require(isActive, "Contract is not active");
        damageEstimate = _damageEstimate;
        landlordEstimateSet = true;
        emit DamageEstimateSet(_damageEstimate);
    }

    function acceptLandlordEstimate() external {
        require(msg.sender == renter, "Only renter can accept the estimate");
        require(landlordEstimateSet, "Landlord must set damage estimate first");
        uint256 damageAmount = damageEstimate < securityDeposit ? damageEstimate : securityDeposit;
        pendingWithdrawals[landlord] += damageAmount;
        pendingWithdrawals[renter] += (securityDeposit - damageAmount);
        emit WithdrawalRequested(landlord, damageAmount);
        emit WithdrawalRequested(renter, securityDeposit - damageAmount);
        isActive = false;
    }

    function rejectLandlordEstimate() external {
        require(msg.sender == renter, "Only renter can reject the estimate");
        require(landlordEstimateSet, "Landlord must set damage estimate first");
        emit EstimateRejected();
    }

    function setRenterCounterEstimate(uint256 _renterCounterEstimate) external {
        require(msg.sender == renter, "Only renter can set the counter estimate");
        require(landlordEstimateSet, "Landlord must set damage estimate first");
        renterCounterEstimate = _renterCounterEstimate;
        renterCounterEstimateSet = true;
        emit CounterEstimateSet(_renterCounterEstimate);
    }

    function acceptRenterCounterEstimate() external {
        require(msg.sender == landlord, "Only landlord can accept the counter estimate");
        require(renterCounterEstimateSet, "Renter must set counter estimate first");
        uint256 damageAmount = renterCounterEstimate < securityDeposit ? renterCounterEstimate : securityDeposit;
        pendingWithdrawals[landlord] += damageAmount;
        pendingWithdrawals[renter] += (securityDeposit - damageAmount);
        emit WithdrawalRequested(landlord, damageAmount);
        emit WithdrawalRequested(renter, securityDeposit - damageAmount);
        isActive = false;
        emit CounterEstimateAccepted();
    }

    function rejectRenterCounterEstimate() external {
        require(msg.sender == landlord, "Only landlord can reject the counter estimate");
        require(renterCounterEstimateSet, "Renter must set counter estimate first");
        
        arbitrationCost = kleros.arbitrationCost("");
        require(currentSecurityDeposit >= arbitrationCost, "Security deposit insufficient to cover arbitration costs");
        
        currentSecurityDeposit -= arbitrationCost;
        raiseDispute();
        emit CounterEstimateRejected();
    }

    function raiseDispute() private {
        require(!disputeRaised, "Dispute already raised");
        require(landlordEstimateSet && renterCounterEstimateSet, "Both estimates must be set before raising a dispute");
        
        disputeID = kleros.createDispute{value: arbitrationCost}(2, "");
        disputeRaised = true;
        emit DisputeRaised(disputeID);
    }

    function rule(uint256 _disputeID, uint256 _ruling) external override {
        require(msg.sender == address(kleros), "Only the arbitrator can rule");
        require(disputeRaised, "No dispute to rule on");
        require(_disputeID == disputeID, "Wrong dispute ID");

        uint256 damageAmount;
        if (_ruling == 1) {
            // Ruling in favor of the landlord
            damageAmount = damageEstimate < currentSecurityDeposit ? damageEstimate : currentSecurityDeposit;
        } else if (_ruling == 2) {
            // Ruling in favor of the renter
            damageAmount = renterCounterEstimate < currentSecurityDeposit ? renterCounterEstimate : currentSecurityDeposit;
        } else {
            // Split the deposit if the ruling is unclear
            damageAmount = currentSecurityDeposit / 2;
        }

        pendingWithdrawals[landlord] += damageAmount;
        pendingWithdrawals[renter] += (currentSecurityDeposit - damageAmount);
        
        emit WithdrawalRequested(landlord, damageAmount);
        emit WithdrawalRequested(renter, currentSecurityDeposit - damageAmount);

        disputeRaised = false;
        isActive = false;
        emit DisputeResolved(_disputeID, _ruling);
    }

     function withdraw() external {
        uint256 amount = pendingWithdrawals[msg.sender];
        require(amount > 0, "No funds to withdraw");
        pendingWithdrawals[msg.sender] = 0;
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Transfer failed");
        emit FundsTransferred(msg.sender, amount);
    }

    function getLandlordBalance() external view returns (uint256) {
        return pendingWithdrawals[landlord];
    }

    function getRenterBalance() external view returns (uint256) {
        return pendingWithdrawals[renter];
    }

    function endContract() private {
        isActive = false;
        uint256 dueAmount = dueRent;
        uint256 refund = 0;

        if (dueAmount > 0) {
            if (dueAmount > securityDeposit) {
                dueAmount = securityDeposit;
            }
            payable(landlord).transfer(dueAmount);
            refund = securityDeposit - dueAmount;
        } else {
            refund = securityDeposit;
        }

        if (refund > 0) {
            payable(renter).transfer(refund);
        }

        emit ContractEnded(refund, dueAmount);
    }

    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function isRentalPeriodEnded() external view returns (bool) {
        return rentalPeriodEnded;
    }

    function getCurrentSecurityDeposit() public view returns (uint256) {
        return currentSecurityDeposit;
    }

    function getArbitrationCost() public view returns (uint256) {
        return kleros.arbitrationCost("");
    }

    receive() external payable {}
}
