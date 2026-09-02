// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { LiFiSwapQuoteLib } from "../libraries/LiFiSwapQuoteLib.sol";
import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 * @title LiFiSwapEnforcer
 * @notice Enforces periodic LiFi swap/bridge delegations backed by signed quotes from a trusted quote signer.
 * @dev Validates calldata via keccak256 hash binding, slippage bounds, and optional same-chain EVM output balance checks.
 * @dev This enforcer operates only in single execution call type and with default execution mode.
 * @dev Terms are validated before the quote signature is trusted, so a delegation with a zero quoteSigner cannot be
 *      satisfied by a malformed signature (ecrecover returns address(0)).
 * @custom:assumptions
 *      - `msg.sender` is expected to be the DelegationManager. Enforcer state (period budget, afterHook context) is
 *        namespaced by `msg.sender`, so a direct external call only pollutes the caller's own namespace and cannot
 *        affect a real delegation's storage (consistent with `ERC20PeriodTransferEnforcer`).
 *      - `DelegationManager.redeemDelegations` has no `nonReentrant` guard; the `balanceOf` call in
 *        `_prepareAfterHookContext` is therefore a reentrancy surface. Impact is bounded: the period budget is already
 *        consumed before the call, and the afterHook context is not yet written, so a reentrant `afterHook` no-ops.
 *        The user-pinned `outputAssetId` must nonetheless be a trusted ERC20.
 */
contract LiFiSwapEnforcer is CaveatEnforcer {
    using ExecutionLib for bytes;
    using LiFiSwapQuoteLib for LiFiSwapQuoteLib.Terms;
    using LiFiSwapQuoteLib for LiFiSwapQuoteLib.SignedLiFiQuote;

    struct PeriodicAllowance {
        uint256 periodAmount;
        uint256 periodDuration;
        uint256 startDate;
        uint256 lastTransferPeriod;
        uint256 transferredInCurrentPeriod;
    }

    struct AfterHookContext {
        bool enabled;
        address outputToken;
        address recipient;
        uint256 minAmountOut;
        uint256 balanceBefore;
    }

    mapping(address delegationManager => mapping(bytes32 delegationHash => PeriodicAllowance)) public periodicAllowances;

    mapping(bytes32 contextKey => AfterHookContext context) public afterHookContexts;

    event SwappedInPeriod(
        address indexed sender,
        address indexed redeemer,
        bytes32 indexed delegationHash,
        address inputToken,
        uint256 periodAmount,
        uint256 periodDuration,
        uint256 startDate,
        uint256 transferredInCurrentPeriod,
        uint256 swapTimestamp
    );

    ////////////////////////////// Public Methods //////////////////////////////

    function getAvailableAmount(
        bytes32 _delegationHash,
        address _delegationManager,
        bytes calldata _terms
    )
        external
        view
        returns (uint256 availableAmount_, bool isNewPeriod_, uint256 currentPeriod_)
    {
        LiFiSwapQuoteLib.Terms memory terms_ = LiFiSwapQuoteLib.decodeTerms(_terms);
        PeriodicAllowance memory storedAllowance_ = periodicAllowances[_delegationManager][_delegationHash];

        if (storedAllowance_.startDate != 0) {
            return _getAvailableAmount(storedAllowance_);
        }

        PeriodicAllowance memory allowance_ = PeriodicAllowance({
            periodAmount: terms_.periodAmount,
            periodDuration: terms_.periodDuration,
            startDate: terms_.startDate,
            lastTransferPeriod: 0,
            transferredInCurrentPeriod: 0
        });
        return _getAvailableAmount(allowance_);
    }

    /**
     * @notice Hook called before a LiFi swap/bridge execution.
     * @dev Validates terms (zero/range checks) BEFORE trusting the quote signature, then verifies the signature
     *      (which now binds `delegationHash` + `chainId`), calldata hash, quote↔terms match, slippage, and period budget.
     * @dev `msg.sender` is expected to be the DelegationManager; see contract-level assumptions.
     */
    function beforeHook(
        bytes calldata _terms,
        bytes calldata _args,
        ModeCode _mode,
        bytes calldata _executionCallData,
        bytes32 _delegationHash,
        address _delegator,
        address _redeemer
    )
        public
        override
        onlySingleCallTypeMode(_mode)
        onlyDefaultExecutionMode(_mode)
    {
        LiFiSwapQuoteLib.Terms memory terms_ = LiFiSwapQuoteLib.decodeTerms(_terms);
        _validateTerms(terms_);

        (LiFiSwapQuoteLib.SignedLiFiQuote memory quote_, bytes memory signature_) = _decodeArgs(_args);

        (address target_, uint256 value_, bytes calldata callData_) = _executionCallData.decodeSingle();

        require(target_ == terms_.lifiDiamond, "LiFiSwapEnforcer:invalid-target");
        require(value_ == 0, "LiFiSwapEnforcer:invalid-value");
        require(callData_.length >= 4, "LiFiSwapEnforcer:invalid-calldata-length");
        require(block.timestamp < quote_.expiration, "LiFiSwapEnforcer:quote-expired");
        require(
            LiFiSwapQuoteLib.recoverQuoteSigner(quote_, _delegationHash, signature_) == terms_.quoteSigner,
            "LiFiSwapEnforcer:invalid-quote-signature"
        );
        require(keccak256(callData_) == quote_.calldataHash, "LiFiSwapEnforcer:calldata-hash-mismatch");

        _validateQuoteMatchesTerms(quote_, terms_, _delegator);
        require(
            LiFiSwapQuoteLib.minAmountOutMeetsSlippage(
                quote_.minAmountOut, quote_.expectedAmountOut, terms_.slippageBps
            ),
            "LiFiSwapEnforcer:slippage-exceeded"
        );

        _validateAndConsumePeriod(terms_, quote_.inputAmount, _delegationHash, _redeemer);

        _prepareAfterHookContext(terms_, quote_, _delegationHash);
    }

    /**
     * @notice Hook called after a LiFi swap/bridge execution.
     * @dev For same-chain EVM recipients/assets, verifies the output token balance increased by `quote.minAmountOut`.
     *      For cross-chain or non-EVM recipients, `beforeHook` does not set a context and this hook silently no-ops —
     *      destination delivery cannot be proven on the source chain. The silent no-op is intentional.
     */
    function afterHook(
        bytes calldata /* _terms */,
        bytes calldata,
        ModeCode _mode,
        bytes calldata,
        bytes32 _delegationHash,
        address,
        address
    )
        public
        override
        onlySingleCallTypeMode(_mode)
        onlyDefaultExecutionMode(_mode)
    {
        bytes32 contextKey_ = _getContextKey(_delegationHash);
        AfterHookContext memory context_ = afterHookContexts[contextKey_];

        if (!context_.enabled) {
            return;
        }

        delete afterHookContexts[contextKey_];

        uint256 balanceAfter_ = IERC20(context_.outputToken).balanceOf(context_.recipient);
        require(
            balanceAfter_ >= context_.balanceBefore + context_.minAmountOut,
            "LiFiSwapEnforcer:insufficient-output-received"
        );
    }

    ////////////////////////////// Internal Methods //////////////////////////////

    function _decodeArgs(bytes calldata _args)
        private
        pure
        returns (LiFiSwapQuoteLib.SignedLiFiQuote memory quote_, bytes memory signature_)
    {
        (quote_, signature_) = abi.decode(_args, (LiFiSwapQuoteLib.SignedLiFiQuote, bytes));
    }

    function _validateQuoteMatchesTerms(
        LiFiSwapQuoteLib.SignedLiFiQuote memory _quote,
        LiFiSwapQuoteLib.Terms memory _terms,
        address _delegator
    )
        private
        pure
    {
        require(_quote.delegator == _delegator, "LiFiSwapEnforcer:invalid-delegator");
        require(_quote.lifiDiamond == _terms.lifiDiamond, "LiFiSwapEnforcer:invalid-diamond");
        require(_quote.inputToken == _terms.inputToken, "LiFiSwapEnforcer:invalid-input-token");
        require(_quote.outputAssetId == _terms.outputAssetId, "LiFiSwapEnforcer:invalid-output-asset");
        require(_quote.outputRecipient == _terms.outputRecipient, "LiFiSwapEnforcer:invalid-output-recipient");
        require(_quote.destinationChainId == _terms.destinationChainId, "LiFiSwapEnforcer:invalid-destination-chain");
    }

    function _validateTerms(LiFiSwapQuoteLib.Terms memory _terms) private pure {
        require(_terms.lifiDiamond != address(0), "LiFiSwapEnforcer:invalid-zero-diamond");
        require(_terms.inputToken != address(0), "LiFiSwapEnforcer:invalid-zero-input-token");
        require(_terms.quoteSigner != address(0), "LiFiSwapEnforcer:invalid-zero-quote-signer");
        require(_terms.outputAssetId != bytes32(0), "LiFiSwapEnforcer:invalid-zero-output-asset");
        require(_terms.outputRecipient != bytes32(0), "LiFiSwapEnforcer:invalid-zero-output-recipient");
        require(_terms.destinationChainId != 0, "LiFiSwapEnforcer:invalid-zero-destination-chain");
        require(_terms.periodAmount > 0, "LiFiSwapEnforcer:invalid-zero-period-amount");
        require(_terms.periodDuration > 0, "LiFiSwapEnforcer:invalid-zero-period-duration");
        require(_terms.startDate > 0, "LiFiSwapEnforcer:invalid-zero-start-date");
        require(_terms.slippageBps < LiFiSwapQuoteLib.BPS_DENOMINATOR, "LiFiSwapEnforcer:invalid-slippage-bps");
    }

    function _validateAndConsumePeriod(
        LiFiSwapQuoteLib.Terms memory _terms,
        uint256 _inputAmount,
        bytes32 _delegationHash,
        address _redeemer
    )
        private
    {
        require(_inputAmount > 0, "LiFiSwapEnforcer:invalid-zero-input-amount");

        PeriodicAllowance storage allowance_ = periodicAllowances[msg.sender][_delegationHash];

        if (allowance_.startDate == 0) {
            require(block.timestamp >= _terms.startDate, "LiFiSwapEnforcer:swap-not-started");

            allowance_.periodAmount = _terms.periodAmount;
            allowance_.periodDuration = _terms.periodDuration;
            allowance_.startDate = _terms.startDate;
        }

        (uint256 available_, bool isNewPeriod_, uint256 currentPeriod_) = _getAvailableAmount(allowance_);

        require(_inputAmount <= available_, "LiFiSwapEnforcer:period-amount-exceeded");

        if (isNewPeriod_) {
            allowance_.lastTransferPeriod = currentPeriod_;
            allowance_.transferredInCurrentPeriod = 0;
        }

        allowance_.transferredInCurrentPeriod += _inputAmount;

        emit SwappedInPeriod(
            msg.sender,
            _redeemer,
            _delegationHash,
            _terms.inputToken,
            _terms.periodAmount,
            _terms.periodDuration,
            _terms.startDate,
            allowance_.transferredInCurrentPeriod,
            block.timestamp
        );
    }

    /**
     * @notice Caches the recipient's output-token balance for the `afterHook` check, when on-chain verification applies.
     * @dev Makes an external `balanceOf` call to the user-pinned `outputAssetId`. This is a reentrancy surface; see the
     *      contract-level assumptions. The context is written only after the external call returns.
     */
    function _prepareAfterHookContext(
        LiFiSwapQuoteLib.Terms memory _terms,
        LiFiSwapQuoteLib.SignedLiFiQuote memory _quote,
        bytes32 _delegationHash
    )
        private
    {
        bytes32 contextKey_ = _getContextKey(_delegationHash);
        delete afterHookContexts[contextKey_];

        if (!LiFiSwapQuoteLib.shouldVerifyOutputOnChain(_terms.destinationChainId, _terms.outputRecipient, _terms.outputAssetId))
        {
            return;
        }

        address outputToken_ = LiFiSwapQuoteLib.toEvmAddress(_terms.outputAssetId);
        address recipient_ = LiFiSwapQuoteLib.toEvmAddress(_terms.outputRecipient);

        afterHookContexts[contextKey_] = AfterHookContext({
            enabled: true,
            outputToken: outputToken_,
            recipient: recipient_,
            minAmountOut: _quote.minAmountOut,
            balanceBefore: IERC20(outputToken_).balanceOf(recipient_)
        });
    }

    function _getAvailableAmount(PeriodicAllowance memory _allowance)
        internal
        view
        returns (uint256 availableAmount_, bool isNewPeriod_, uint256 currentPeriod_)
    {
        if (block.timestamp < _allowance.startDate) {
            return (0, false, 0);
        }

        currentPeriod_ = (block.timestamp - _allowance.startDate) / _allowance.periodDuration + 1;

        isNewPeriod_ = (_allowance.lastTransferPeriod != currentPeriod_);

        uint256 alreadyTransferred_ = isNewPeriod_ ? 0 : _allowance.transferredInCurrentPeriod;

        availableAmount_ = _allowance.periodAmount > alreadyTransferred_
            ? _allowance.periodAmount - alreadyTransferred_
            : 0;
    }

    function _getContextKey(bytes32 _delegationHash) private view returns (bytes32) {
        return keccak256(abi.encode(msg.sender, _delegationHash));
    }
}
