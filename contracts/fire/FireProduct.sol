// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.2;

import "@etherisc/gif-interface/contracts/components/Product.sol";

import "./FireOracle.sol";

contract FireProduct is Product {

    // constants
    bytes32 public constant VERSION = "0.0.1";
    bytes32 public constant POLICY_FLOW = "PolicyDefaultFlow";

    uint256 public constant PAYOUT_FACTOR_MEDIUM = 5;
    uint256 public constant PAYOUT_FACTOR_LARGE = 100;

    string public constant CALLBACK_METHOD_NAME = "oracleCallback";

    // variables
    // TODO should be framework feature
    bytes32 [] private _applications; // useful for debugging, might need to get rid of this
    uint256 public _oracleId;

    mapping(string => bool) public activePolicy;

    // events
    event LogFirePolicyCreated(address policyHolder, string objectName, bytes32 policyId);
    event LogFirePolicyExpired(string objectName, bytes32 policyId);
    event LogFireOracleCallbackReceived(uint256 requestId, bytes32 policyId, bytes fireCategory);
    event LogFireClaimConfirmed(bytes32 policyId, uint256 claimId, uint256 payoutAmount);
    event LogFirePayoutExecuted(bytes32 policyId, uint256 claimId, uint256 payoutId, uint256 payoutAmount);

    constructor(
        bytes32 productName,
        address token,
        uint256 oracleId,
        uint256 riskpoolId,
        address registry
    )
        Product(productName, token, POLICY_FLOW, riskpoolId, registry)
    {
        _oracleId = oracleId;
    }

    function applications() external view returns(uint256 numberOfApplications) {
        return _applications.length;
    }

    function getApplicationId(uint256 idx) external view returns(bytes32 processId) {
        require(idx < _applications.length, "ERROR:FI-001:APPLICATION_INDEX_TOO_LARGE");
        return _applications[idx];
    }

    function decodeApplicationParameterFromData(bytes memory data) 
        external
        pure
        returns(string memory objectName)
    {
        return abi.decode(data, (string));
    }


    function encodeApplicationParametersToData(string memory objectName)
        public
        pure
        returns(bytes memory data)
    {
        return abi.encode(objectName);
    }

    function applyForPolicy(
        string calldata objectName,
        uint256 premiumAmount,
        uint256 sumInsuredAmount
    )
        external 
        returns (bytes32 processId, uint256 requestId) 
    {
        // Validate input parameters
        require(premiumAmount > 0, "ERROR:FI-010:INVALID_PREMIUM");
        require(!activePolicy[objectName], "ERROR:FI-011:ACTIVE_POLICY_EXISTS");

        // Create and underwrite new application
        address policyHolder = msg.sender;
        bytes memory metaData = "";
        bytes memory applicationData = encodeApplicationParametersToData(objectName);

        processId = _newApplication(
            policyHolder, 
            premiumAmount, 
            sumInsuredAmount, 
            metaData, 
            applicationData);

        _underwrite(processId);
        
        // Update activ state for object
        activePolicy[objectName] = true;
        _applications.push(processId);

        // trigger fire observation for object id via oracle call
        requestId = _request(
            processId,
            abi.encode(objectName),
            CALLBACK_METHOD_NAME,
            _oracleId
        );

        emit LogFirePolicyCreated(policyHolder, objectName, processId);
    }

    function expirePolicy(bytes32 policyId) external {
        // Get policy data 
        bytes memory applicationData = _getApplication(policyId).data;
        (
            address payable policyHolder, 
            string memory objectName, 
            uint256 premium
        ) = abi.decode(applicationData, (address, string, uint256));

        // Validate input parameter
        require(premium > 0, "ERROR:FI-004:NON_EXISTING_POLICY");
        require(activePolicy[objectName], "ERROR:FI-005:EXPIRED_POLICY");

        _expire(policyId);
        activePolicy[objectName] = false;

        emit LogFirePolicyExpired(objectName, policyId);
    }

    function oracleCallback(uint256 requestId, bytes32 policyId, bytes calldata response)
        external
        onlyOracle
    {
        emit LogFireOracleCallbackReceived(requestId, policyId, response);

        // Get policy data for oracle response
        bytes memory applicationData = _getApplication(policyId).data;
        (
            address payable policyHolder, 
            string memory objectName, 
            uint256 premium
        ) = abi.decode(applicationData, (address, string, uint256));

        // Validate input parameter
        require(activePolicy[objectName], "ERROR:FI-006:EXPIRED_POLICY");

        // Get oracle response data
        (bytes1 fireCategory) = abi.decode(response, (bytes1));

        // Claim handling based on reponse to greeting provided by oracle 
        _handleClaim(policyId, policyHolder, premium, fireCategory);
    }


    function getOracleId() external view returns(uint256 oracleId) {
        return _oracleId;
    }


    function _handleClaim(
        bytes32 policyId, 
        address payable policyHolder, 
        uint256 premium, 
        bytes1 fireCategory
    ) 
        internal 
    {
        uint256 payoutAmount = _calculatePayoutAmount(premium, fireCategory);

        // no claims handling for payouts == 0
        if (payoutAmount > 0) {
            uint256 claimId = _newClaim(policyId, payoutAmount, "");
            _confirmClaim(policyId, claimId, payoutAmount);

            emit LogFireClaimConfirmed(policyId, claimId, payoutAmount);

            uint256 payoutId = _newPayout(policyId, claimId, payoutAmount, "");
            _processPayout(policyId, payoutId);

            emit LogFirePayoutExecuted(policyId, claimId, payoutId, payoutAmount);
        }
    }

    function _calculatePayoutAmount(uint256 premium, bytes1 fireCategory) 
        internal 
        pure 
        returns(uint256 payoutAmount) 
    {
        if (fireCategory == 'M') {
            payoutAmount = PAYOUT_FACTOR_MEDIUM * premium;
        } else if (fireCategory == 'L') { 
            payoutAmount = PAYOUT_FACTOR_LARGE * premium;
        } else {
            // small fires considered below deductible, no payout
            payoutAmount = 0;
        }
    }
}