// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 * @title ERC20BalanceLimitEnforcer
 * @dev This contract allows setting up some guardrails around balance limits. By specifying an account 
 * limit (upper/lower). One can enforce that execution is prevented if the ERC20 balance is too high before execution,
 * or execution reverts if the ERC20 balance is too low after all executions. Upper/lower limit is selected based 
 * on the `enforceLowerLimit` flag.
 * @dev This contract has no enforcement of how the balance changes. It's meant to be used alongside additional enforcers to
 * create granular permissions.
 * @dev This enforcer operates only in default execution mode.
 */
contract ERC20BalanceLimitEnforcer is CaveatEnforcer {

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice This function enforces that the delegators ERC20 balance respects upper limit before all executions.
     * @param _terms 73 packed bytes where:
     * - first byte: boolean indicating if the balance should be higher than (true | 0x01) or lower than (false | 0x00)
     * - next 20 bytes: address of the token
     * - next 20 bytes: address of the recipient
     * - next 32 bytes: balance limit guardrail amount (i.e., upper OR lower bound, depending on
     * enforceLowerLimit)
     */
    function beforeAllHook(
        bytes calldata _terms,
        bytes calldata,
        ModeCode,
        bytes calldata,
        bytes32 _delegationHash,
        address,
        address
    )
        public
        override
    {
        (bool enforceLowerLimit, address token_, address, uint256 amount_) = getTermsInfo(_terms);
        uint256 balance_ = IERC20(token_).balanceOf(_delegator);
        if (!enforceLowerLimit) {
            require(balance_ < amount_, "ERC20BalanceLimitEnforcer:exceeds-upper-balance-limit");
        }
    }

    /**
     * @notice This function enforces that the delegators ERC20 balance respects lower limit after all executions.
     * @param _terms 73 packed bytes where:
     * - first byte: boolean indicating if the balance should be higher than (true | 0x01) or lower than (false | 0x00)
     * - next 20 bytes: address of the token
     * - next 20 bytes: address of the recipient
     * - next 32 bytes: balance limit guardrail amount (i.e., upper OR lower bound, depending on
     * enforceLowerLimit)
     */
    function afterAllHook(
        bytes calldata _terms,
        bytes calldata,
        ModeCode,
        bytes calldata,
        bytes32 _delegationHash,
        address,
        address
    )
        public
        override
    {
        (bool enforceLowerLimit, address token_, address, uint256 amount_) = getTermsInfo(_terms);
        uint256 balance_ = IERC20(token_).balanceOf(_delegator);
        if (enforceLowerLimit) {
            require(balance_ > amount_, "ERC20BalanceLimitEnforcer:violated-lower-balance-limit");
        }
    }

    /**
     * @notice Decodes the terms used in this CaveatEnforcer.
     * @param _terms encoded data that is used during the execution hooks.
     * @return enforceLowerLimit_ Boolean indicating if the balance should be higher than (true | 0x01) or lower than (false | 0x00) a limit.
     * @return token_ The address of the token.
     * @return recipient_ The address of the recipient.
     * @return amount_ Balance limit guardrail amount (i.e., upper OR lower bound, depending on
     * enforceLowerLimit)
     */
    function getTermsInfo(bytes calldata _terms)
        public
        pure
        returns (bool enforceLowerLimit_, address token_, address recipient_, uint256 amount_)
    {
        require(_terms.length == 73, "ERC20BalanceLimitEnforcer:invalid-terms-length");
        enforceLowerLimit_ = _terms[0] != 0;
        token_ = address(bytes20(_terms[1:21]));
        recipient_ = address(bytes20(_terms[21:41]));
        amount_ = uint256(bytes32(_terms[41:]));
    }
}
