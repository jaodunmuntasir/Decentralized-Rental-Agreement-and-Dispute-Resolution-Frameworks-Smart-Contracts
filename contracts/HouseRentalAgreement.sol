// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract HouseRentalAgreement {
    address public landlord;
    address public renter;
    uint256 public securityDeposit;
    uint256 public baseRent;
    uint256 public rentPeriodInMonths;
    uint256 public rentStartDate;
    uint256 public currentMonth;
    uint256 public dueRent;
    bool public isActive;
    bool public isSecurityDepositPaid;

    struct MonthlyRent {
        uint256 baseRent;
        uint256 utilities;
        uint256 due;
        bool paid;
    }

    mapping(uint256 => MonthlyRent) public monthlyRents;

    event AgreementTermsSet(uint256 securityDeposit, uint256 baseRent, uint256 rentPeriodInMonths);
    event SecurityDepositPaid(uint256 amount);
    event UtilitiesRecorded(uint256 month, uint256 amount);
    event RentPaid(uint256 month, uint256 amount);
    event RentSkipped(uint256 month, uint256 amount);
    event RentTransferred(uint256 month, uint256 amount);
    event ContractEnded(uint256 securityDepositReturned, uint256 dueAmountPaid);

    constructor(address _renter) {
        landlord = msg.sender;
        renter = _renter;
        isActive = false;
        isSecurityDepositPaid = false;
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

        // Transfer rent to landlord
        payable(landlord).transfer(totalRent);
        emit RentTransferred(currentMonth, totalRent);

        if (currentMonth == rentPeriodInMonths) {
            endContract();
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
}