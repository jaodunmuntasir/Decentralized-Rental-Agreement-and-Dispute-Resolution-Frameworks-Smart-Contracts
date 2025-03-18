// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

/**
 * @title ILocalArbitrator
 * @dev Interface for the local arbitration system
 */
interface ILocalArbitrator {
    function createDispute(uint256 _landlordEstimate, uint256 _renterEstimate) external payable returns (uint256);
    function getArbitrationCost() external view returns (uint256);
}

/**
 * @title LocalArbitrator
 * @author Muntasir Jaodun
 * @notice Implements a local arbitration system for resolving rental disputes
 * @dev Optimized for gas efficiency and security
 */
contract LocalArbitrator is ReentrancyGuard {
    using SafeMath for uint256;
    
    // ===============================
    // State variables
    // ===============================
    
    address public immutable arbitrator;
    uint256 public disputeCount;
    uint256 public arbitrationFee;
    uint256 public refundPercentage;
    
    // ===============================
    // Data structures
    // ===============================
    
    struct Dispute {
        address rentalContract;
        uint256 landlordEstimate;
        uint256 renterEstimate;
        bool isResolved;
        uint256 ruling;
        uint256 creationTime;
        uint256 resolutionTime;
        string evidenceURI;
    }
    
    // ===============================
    // Mappings
    // ===============================
    
    mapping(uint256 => Dispute) public disputes;
    mapping(address => bool) public authorizedContracts;
    
    // ===============================
    // Events
    // ===============================
    
    event DisputeCreated(uint256 indexed disputeId, address indexed rentalContract, uint256 landlordEstimate, uint256 renterEstimate);
    event DisputeResolved(uint256 indexed disputeId, uint256 ruling, uint256 resolutionTime);
    event ArbitrationFeeUpdated(uint256 oldFee, uint256 newFee);
    event RefundPercentageUpdated(uint256 oldPercentage, uint256 newPercentage);
    event ContractAuthorized(address indexed contractAddress);
    event ContractDeauthorized(address indexed contractAddress);
    event EvidenceSubmitted(uint256 indexed disputeId, string evidenceURI);
    event FeesWithdrawn(address indexed arbitrator, uint256 amount);
    
    // ===============================
    // Modifiers
    // ===============================
    
    /**
     * @dev Ensures only the arbitrator can call the function
     */
    modifier onlyArbitrator() {
        require(msg.sender == arbitrator, "LA: Only arbitrator can call");
        _;
    }
    
    /**
     * @dev Ensures only authorized rental contracts can call the function
     */
    modifier onlyAuthorizedContract() {
        require(authorizedContracts[msg.sender], "LA: Contract not authorized");
        _;
    }
    
    /**
     * @dev Ensures dispute exists and is not resolved
     */
    modifier validUnresolvedDispute(uint256 _disputeId) {
        require(_disputeId > 0 && _disputeId <= disputeCount, "LA: Invalid dispute ID");
        require(!disputes[_disputeId].isResolved, "LA: Dispute already resolved");
        _;
    }
    
    // ===============================
    // Constructor & initialization
    // ===============================
    
    /**
     * @dev Contract constructor
     * @param _arbitrator Address of the arbitrator
     * @param _arbitrationFee Initial arbitration fee
     * @param _refundPercentage Percentage of fee to refund (0-100)
     */
    constructor(address _arbitrator, uint256 _arbitrationFee, uint256 _refundPercentage) {
        require(_arbitrator != address(0), "LA: Arbitrator cannot be zero address");
        require(_refundPercentage <= 100, "LA: Refund percentage cannot exceed 100");
        
        arbitrator = _arbitrator;
        arbitrationFee = _arbitrationFee;
        refundPercentage = _refundPercentage;
        disputeCount = 0;
    }
    
    // ===============================
    // Dispute management
    // ===============================
    
    /**
     * @dev Creates a new dispute
     * @param _landlordEstimate Landlord's damage estimate
     * @param _renterEstimate Renter's counter estimate
     * @return disputeId The ID of the created dispute
     */
    function createDispute(uint256 _landlordEstimate, uint256 _renterEstimate) 
        external 
        payable 
        onlyAuthorizedContract 
        nonReentrant 
        returns (uint256) 
    {
        require(msg.value >= arbitrationFee, "LA: Insufficient arbitration fee");
        
        // Handle any excess payment
        uint256 excess = msg.value.sub(arbitrationFee);
        if (excess > 0) {
            (bool success, ) = payable(msg.sender).call{value: excess}("");
            require(success, "LA: Failed to return excess payment");
        }
        
        // Create dispute
        disputeCount = disputeCount.add(1);
        uint256 disputeId = disputeCount;
        
        disputes[disputeId] = Dispute({
            rentalContract: msg.sender,
            landlordEstimate: _landlordEstimate,
            renterEstimate: _renterEstimate,
            isResolved: false,
            ruling: 0,
            creationTime: block.timestamp,
            resolutionTime: 0,
            evidenceURI: ""
        });
        
        emit DisputeCreated(disputeId, msg.sender, _landlordEstimate, _renterEstimate);
        return disputeId;
    }
    
    /**
     * @dev Submits evidence for a dispute
     * @param _disputeId The ID of the dispute
     * @param _evidenceURI URI pointing to the evidence
     */
    function submitEvidence(uint256 _disputeId, string calldata _evidenceURI) 
        external 
        onlyArbitrator 
        validUnresolvedDispute(_disputeId) 
    {
        require(bytes(_evidenceURI).length > 0, "LA: Evidence URI cannot be empty");
        
        disputes[_disputeId].evidenceURI = _evidenceURI;
        
        emit EvidenceSubmitted(_disputeId, _evidenceURI);
    }
    
    /**
     * @dev Resolves a dispute
     * @param _disputeId The ID of the dispute
     * @param _ruling The arbitrator's ruling (1: landlord, 2: renter)
     */
    function resolveDispute(uint256 _disputeId, uint256 _ruling) 
        external 
        onlyArbitrator 
        validUnresolvedDispute(_disputeId) 
        nonReentrant 
    {
        require(_ruling == 1 || _ruling == 2, "LA: Invalid ruling");
        
        Dispute storage dispute = disputes[_disputeId];
        dispute.isResolved = true;
        dispute.ruling = _ruling;
        dispute.resolutionTime = block.timestamp;
        
        // Calculate refund amount
        uint256 refundAmount = arbitrationFee.mul(refundPercentage).div(100);
        
        // Call the rental contract to execute the ruling
        (bool success, ) = dispute.rentalContract.call(
            abi.encodeWithSignature(
                "executeRuling(uint256,uint256,uint256)", 
                _disputeId, 
                _ruling,
                refundAmount
            )
        );
        require(success, "LA: Failed to execute ruling");
        
        emit DisputeResolved(_disputeId, _ruling, block.timestamp);
    }
    
    // ===============================
    // Contract management
    // ===============================
    
    /**
     * @dev Authorizes a rental contract to use this arbitrator
     * @param _contractAddress The address of the rental contract
     */
    function authorizeContract(address _contractAddress) 
        external 
        onlyArbitrator 
    {
        require(_contractAddress != address(0), "LA: Contract cannot be zero address");
        require(!authorizedContracts[_contractAddress], "LA: Contract already authorized");
        
        authorizedContracts[_contractAddress] = true;
        
        emit ContractAuthorized(_contractAddress);
    }
    
    /**
     * @dev Deauthorizes a rental contract
     * @param _contractAddress The address of the rental contract
     */
    function deauthorizeContract(address _contractAddress) 
        external 
        onlyArbitrator 
    {
        require(authorizedContracts[_contractAddress], "LA: Contract not authorized");
        
        authorizedContracts[_contractAddress] = false;
        
        emit ContractDeauthorized(_contractAddress);
    }
    
    /**
     * @dev Updates the arbitration fee
     * @param _newFee The new arbitration fee
     */
    function updateArbitrationFee(uint256 _newFee) 
        external 
        onlyArbitrator 
    {
        uint256 oldFee = arbitrationFee;
        arbitrationFee = _newFee;
        
        emit ArbitrationFeeUpdated(oldFee, _newFee);
    }
    
    /**
     * @dev Updates the refund percentage
     * @param _newPercentage The new refund percentage (0-100)
     */
    function updateRefundPercentage(uint256 _newPercentage) 
        external 
        onlyArbitrator 
    {
        require(_newPercentage <= 100, "LA: Refund percentage cannot exceed 100");
        
        uint256 oldPercentage = refundPercentage;
        refundPercentage = _newPercentage;
        
        emit RefundPercentageUpdated(oldPercentage, _newPercentage);
    }
    
    // ===============================
    // Financial operations
    // ===============================
    
    /**
     * @dev Allows the arbitrator to withdraw accumulated fees
     */
    function withdrawFees() 
        external 
        onlyArbitrator 
        nonReentrant 
    {
        uint256 amount = address(this).balance;
        require(amount > 0, "LA: No funds to withdraw");
        
        (bool success, ) = arbitrator.call{value: amount}("");
        require(success, "LA: Transfer failed");
        
        emit FeesWithdrawn(arbitrator, amount);
    }
    
    // ===============================
    // View functions
    // ===============================
    
    /**
     * @dev Returns the current arbitration cost
     * @return uint256 The arbitration cost
     */
    function getArbitrationCost() 
        external 
        view 
        returns (uint256) 
    {
        return arbitrationFee;
    }
    
    /**
     * @dev Returns dispute details
     * @param _disputeId The ID of the dispute
     * @return rentalContract The address of the rental contract
     * @return landlordEstimate The landlord's damage estimate
     * @return renterEstimate The renter's counter estimate
     * @return isResolved Whether the dispute is resolved
     * @return ruling The arbitrator's ruling
     * @return creationTime The time when the dispute was created
     * @return resolutionTime The time when the dispute was resolved
     * @return evidenceURI The URI pointing to the evidence
     */
    function getDispute(uint256 _disputeId) 
        external 
        view 
        returns (
            address rentalContract,
            uint256 landlordEstimate,
            uint256 renterEstimate,
            bool isResolved,
            uint256 ruling,
            uint256 creationTime,
            uint256 resolutionTime,
            string memory evidenceURI
        ) 
    {
        require(_disputeId > 0 && _disputeId <= disputeCount, "LA: Invalid dispute ID");
        
        Dispute storage dispute = disputes[_disputeId];
        return (
            dispute.rentalContract,
            dispute.landlordEstimate,
            dispute.renterEstimate,
            dispute.isResolved,
            dispute.ruling,
            dispute.creationTime,
            dispute.resolutionTime,
            dispute.evidenceURI
        );
    }
    
    /**
     * @dev Returns the count of created disputes
     * @return uint256 The number of disputes
     */
    function getDisputeCount() 
        external 
        view 
        returns (uint256) 
    {
        return disputeCount;
    }
    
    /**
     * @dev Returns whether a contract is authorized
     * @param _contractAddress The address to check
     * @return bool Whether the contract is authorized
     */
    function isContractAuthorized(address _contractAddress) 
        external 
        view 
        returns (bool) 
    {
        return authorizedContracts[_contractAddress];
    }
    
    /**
     * @dev Fallback function to receive ETH
     */
    receive() 
        external 
        payable 
    {
        // Accept ETH payments
    }
}
