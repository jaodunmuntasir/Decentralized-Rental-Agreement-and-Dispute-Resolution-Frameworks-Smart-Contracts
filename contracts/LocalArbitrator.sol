// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract LocalArbitrator {
    address public arbitrator;
    uint256 public disputeCount;

    struct Dispute {
        address rentalContract;
        uint256 landlordEstimate;
        uint256 renterEstimate;
        bool isResolved;
        uint256 ruling;
    }

    mapping(uint256 => Dispute) public disputes;

    event DisputeCreated(uint256 disputeId, address rentalContract);
    event DisputeResolved(uint256 disputeId, uint256 ruling);

    modifier onlyArbitrator() {
        require(msg.sender == arbitrator, "Only the arbitrator can perform this action");
        _;
    }

    constructor(address _arbitrator) {
        arbitrator = _arbitrator;
        disputeCount = 0;
    }

    function createDispute(uint256 _landlordEstimate, uint256 _renterEstimate) external payable returns (uint256) {
        disputeCount++;
        disputes[disputeCount] = Dispute({
            rentalContract: msg.sender,
            landlordEstimate: _landlordEstimate,
            renterEstimate: _renterEstimate,
            isResolved: false,
            ruling: 0
        });

        emit DisputeCreated(disputeCount, msg.sender);
        return disputeCount;
    }

    function resolveDispute(uint256 _disputeId, uint256 _ruling) external onlyArbitrator {
        require(_disputeId > 0 && _disputeId <= disputeCount, "Invalid dispute ID");
        require(!disputes[_disputeId].isResolved, "Dispute already resolved");
        require(_ruling == 1 || _ruling == 2, "Invalid ruling");

        Dispute storage dispute = disputes[_disputeId];
        dispute.isResolved = true;
        dispute.ruling = _ruling;

        // Call the rental contract to execute the ruling
        (bool success, ) = dispute.rentalContract.call(abi.encodeWithSignature("executeRuling(uint256,uint256)", _disputeId, _ruling));
        require(success, "Failed to execute ruling on rental contract");

        emit DisputeResolved(_disputeId, _ruling);
    }

    function getDispute(uint256 _disputeId) external view returns (
        address rentalContract,
        uint256 landlordEstimate,
        uint256 renterEstimate,
        bool isResolved,
        uint256 ruling
    ) {
        require(_disputeId > 0 && _disputeId <= disputeCount, "Invalid dispute ID");
        Dispute storage dispute = disputes[_disputeId];
        return (
            dispute.rentalContract,
            dispute.landlordEstimate,
            dispute.renterEstimate,
            dispute.isResolved,
            dispute.ruling
        );
    }

    // Add a withdraw function for the arbitrator to claim their fees
    function withdrawFees() external {
        require(msg.sender == arbitrator, "Only the arbitrator can withdraw fees");
        uint256 amount = address(this).balance;
        (bool success, ) = arbitrator.call{value: amount}("");
        require(success, "Transfer failed");
    }

    function getArbitrationCost() external pure returns (uint256) {
        return 1; // No cost for local arbitration
    }

    receive() external payable {}
}
