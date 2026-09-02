// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { Caveat, Delegation, Execution } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { LiFiSwapEnforcer } from "../../src/enforcers/LiFiSwapEnforcer.sol";
import { LiFiSwapQuoteLib } from "../../src/libraries/LiFiSwapQuoteLib.sol";
import { BasicERC20 } from "../utils/BasicERC20.t.sol";
import { MockLiFiDiamond } from "../utils/MockLiFiDiamond.t.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";

contract LiFiSwapEnforcerTest is CaveatEnforcerBaseTest {
    LiFiSwapEnforcer public lifiSwapEnforcer;
    MockLiFiDiamond public mockDiamond;
    BasicERC20 public usdc;
    BasicERC20 public wbtc;

    address public alice;
    address public bob;
    address public quoteSignerAddress;
    uint256 public quoteSignerPrivateKey;

    bytes32 public dummyDelegationHash = keccak256("lifi-swap-delegation");
    address public redeemer = address(0xBEEF);

    uint256 public periodAmount = 1000;
    uint256 public periodDuration = 1 days;
    uint256 public startDate;
    uint256 public slippageBps = 50;
    uint256 public inputAmount = 500;
    uint256 public expectedAmountOut = 100;
    uint256 public minAmountOut = 100;

    uint256 public constant LIFI_CHAIN_ID_BTC = 20_000_000_000_001;

    function setUp() public override {
        super.setUp();
        lifiSwapEnforcer = new LiFiSwapEnforcer();
        vm.label(address(lifiSwapEnforcer), "LiFi Swap Enforcer");

        mockDiamond = new MockLiFiDiamond();
        vm.label(address(mockDiamond), "Mock LiFi Diamond");

        alice = address(users.alice.deleGator);
        bob = address(users.bob.deleGator);

        (quoteSignerAddress, quoteSignerPrivateKey) = makeAddrAndKey("QuoteSigner");

        usdc = new BasicERC20(alice, "USD Coin", "USDC", 1_000_000 ether);
        wbtc = new BasicERC20(address(this), "Wrapped BTC", "WBTC", 0);

        startDate = block.timestamp;
    }

    ////////////////////// Valid cases //////////////////////

    function test_beforeHook_acceptsValidSameChainQuote() public {
        _runBeforeHook(_buildTerms(block.chainid), _buildQuote(block.chainid), _buildSwapCalldata(block.chainid));
    }

    function test_beforeHook_acceptsValidCrossChainQuote() public {
        bytes32 btcRecipient_ = bytes32(uint256(0xdeadbeef));
        LiFiSwapQuoteLib.Terms memory terms_ = _buildTerms(LIFI_CHAIN_ID_BTC);
        terms_.outputRecipient = btcRecipient_;
        terms_.outputAssetId = bytes32(uint256(0x1234));

        LiFiSwapQuoteLib.SignedLiFiQuote memory quote_ = _buildQuote(LIFI_CHAIN_ID_BTC);
        quote_.outputRecipient = btcRecipient_;
        quote_.outputAssetId = terms_.outputAssetId;

        bytes memory bridgeCalldata_ = abi.encodeWithSelector(MockLiFiDiamond.execute.selector, hex"abcd");
        bytes memory execData_ = _encodeSingleExecution(address(mockDiamond), 0, bridgeCalldata_);

        _runBeforeHookWithExecution(LiFiSwapQuoteLib.encodeTerms(terms_), quote_, execData_, bridgeCalldata_);
    }

    function test_crossChain_afterHook_skipsBalanceCheck() public {
        bytes32 btcRecipient_ = bytes32(uint256(0xdeadbeef));
        LiFiSwapQuoteLib.Terms memory terms_ = _buildTerms(LIFI_CHAIN_ID_BTC);
        terms_.outputRecipient = btcRecipient_;
        terms_.outputAssetId = bytes32(uint256(0x1234));

        LiFiSwapQuoteLib.SignedLiFiQuote memory quote_ = _buildQuote(LIFI_CHAIN_ID_BTC);
        quote_.outputRecipient = btcRecipient_;
        quote_.outputAssetId = terms_.outputAssetId;

        bytes memory bridgeCalldata_ = abi.encodeWithSelector(MockLiFiDiamond.execute.selector, hex"abcd");
        bytes memory execData_ = _encodeSingleExecution(address(mockDiamond), 0, bridgeCalldata_);
        bytes memory args_ = _encodeArgs(quote_, bridgeCalldata_, dummyDelegationHash);

        vm.prank(address(delegationManager));
        lifiSwapEnforcer.beforeHook(
            LiFiSwapQuoteLib.encodeTerms(terms_), args_, singleDefaultMode, execData_, dummyDelegationHash, alice, redeemer
        );

        vm.prank(address(delegationManager));
        lifiSwapEnforcer.afterHook(
            LiFiSwapQuoteLib.encodeTerms(terms_), args_, singleDefaultMode, execData_, dummyDelegationHash, alice, redeemer
        );
    }

    function test_periodBudget_resetsOnNewPeriod() public {
        _runBeforeHook(_buildTerms(block.chainid), _buildQuote(block.chainid), _buildSwapCalldata(block.chainid));

        vm.warp(block.timestamp + periodDuration + 1);

        _runBeforeHook(_buildTerms(block.chainid), _buildQuote(block.chainid), _buildSwapCalldata(block.chainid));
    }

    ////////////////////// Revert cases //////////////////////

    function test_revert_invalidTermsLength() public {
        vm.prank(address(delegationManager));
        vm.expectRevert("LiFiSwapQuoteLib:invalid-terms-length");
        lifiSwapEnforcer.beforeHook(new bytes(283), hex"", singleDefaultMode, hex"", dummyDelegationHash, alice, redeemer);
    }

    function test_revert_invalidTarget() public {
        bytes memory execData_ = _encodeSingleExecution(address(0xdead), 0, _buildSwapCalldata(block.chainid));
        vm.prank(address(delegationManager));
        vm.expectRevert("LiFiSwapEnforcer:invalid-target");
        lifiSwapEnforcer.beforeHook(
            LiFiSwapQuoteLib.encodeTerms(_buildTerms(block.chainid)),
            _encodeArgs(_buildQuote(block.chainid), _buildSwapCalldata(block.chainid), dummyDelegationHash),
            singleDefaultMode,
            execData_,
            dummyDelegationHash,
            alice,
            redeemer
        );
    }

    function test_revert_calldataHashMismatch() public {
        LiFiSwapQuoteLib.SignedLiFiQuote memory quote_ = _buildQuote(block.chainid);
        quote_.calldataHash = keccak256("tampered");
        bytes memory args_ = abi.encode(quote_, _signQuote(quoteSignerPrivateKey, quote_, dummyDelegationHash));

        vm.prank(address(delegationManager));
        vm.expectRevert("LiFiSwapEnforcer:calldata-hash-mismatch");
        lifiSwapEnforcer.beforeHook(
            LiFiSwapQuoteLib.encodeTerms(_buildTerms(block.chainid)),
            args_,
            singleDefaultMode,
            _encodeSingleExecution(address(mockDiamond), 0, _buildSwapCalldata(block.chainid)),
            dummyDelegationHash,
            alice,
            redeemer
        );
    }

    function test_revert_expiredQuote() public {
        LiFiSwapQuoteLib.SignedLiFiQuote memory quote_ = _buildQuote(block.chainid);
        quote_.expiration = block.timestamp;

        vm.prank(address(delegationManager));
        vm.expectRevert("LiFiSwapEnforcer:quote-expired");
        lifiSwapEnforcer.beforeHook(
            LiFiSwapQuoteLib.encodeTerms(_buildTerms(block.chainid)),
            _encodeArgs(quote_, _buildSwapCalldata(block.chainid), dummyDelegationHash),
            singleDefaultMode,
            _encodeSingleExecution(address(mockDiamond), 0, _buildSwapCalldata(block.chainid)),
            dummyDelegationHash,
            alice,
            redeemer
        );
    }

    function test_revert_invalidQuoteSignature() public {
        LiFiSwapQuoteLib.SignedLiFiQuote memory quote_ = _buildQuote(block.chainid);
        bytes memory badSignature_ = _signQuote(quoteSignerPrivateKey + 1, quote_, dummyDelegationHash);

        vm.prank(address(delegationManager));
        vm.expectRevert("LiFiSwapEnforcer:invalid-quote-signature");
        lifiSwapEnforcer.beforeHook(
            LiFiSwapQuoteLib.encodeTerms(_buildTerms(block.chainid)),
            abi.encode(quote_, badSignature_),
            singleDefaultMode,
            _encodeSingleExecution(address(mockDiamond), 0, _buildSwapCalldata(block.chainid)),
            dummyDelegationHash,
            alice,
            redeemer
        );
    }

    function test_revert_slippageExceeded() public {
        LiFiSwapQuoteLib.SignedLiFiQuote memory quote_ = _buildQuote(block.chainid);
        quote_.minAmountOut = 90;

        vm.prank(address(delegationManager));
        vm.expectRevert("LiFiSwapEnforcer:slippage-exceeded");
        lifiSwapEnforcer.beforeHook(
            LiFiSwapQuoteLib.encodeTerms(_buildTerms(block.chainid)),
            _encodeArgs(quote_, _buildSwapCalldata(block.chainid), dummyDelegationHash),
            singleDefaultMode,
            _encodeSingleExecution(address(mockDiamond), 0, _buildSwapCalldata(block.chainid)),
            dummyDelegationHash,
            alice,
            redeemer
        );
    }

    function test_revert_periodAmountExceeded() public {
        LiFiSwapQuoteLib.Terms memory terms_ = _buildTerms(block.chainid);
        terms_.periodAmount = 500;
        bytes memory encodedTerms_ = LiFiSwapQuoteLib.encodeTerms(terms_);
        bytes32 delegationHash_ = keccak256("period-exceeded");

        LiFiSwapQuoteLib.SignedLiFiQuote memory quote_ = _buildQuote(block.chainid);
        bytes memory callData_ = _buildSwapCalldata(block.chainid);
        bytes memory execData_ = _encodeSingleExecution(address(mockDiamond), 0, callData_);

        vm.prank(address(delegationManager));
        lifiSwapEnforcer.beforeHook(
            encodedTerms_, _encodeArgs(quote_, callData_, delegationHash_), singleDefaultMode, execData_, delegationHash_, alice, redeemer
        );

        vm.prank(address(delegationManager));
        vm.expectRevert("LiFiSwapEnforcer:period-amount-exceeded");
        lifiSwapEnforcer.beforeHook(
            encodedTerms_, _encodeArgs(quote_, callData_, delegationHash_), singleDefaultMode, execData_, delegationHash_, alice, redeemer
        );
    }

    function test_revert_invalidOutputRecipient() public {
        LiFiSwapQuoteLib.Terms memory terms_ = _buildTerms(block.chainid);
        LiFiSwapQuoteLib.SignedLiFiQuote memory quote_ = _buildQuote(block.chainid);
        quote_.outputRecipient = bytes32(uint256(uint160(bob)));

        vm.prank(address(delegationManager));
        vm.expectRevert("LiFiSwapEnforcer:invalid-output-recipient");
        lifiSwapEnforcer.beforeHook(
            LiFiSwapQuoteLib.encodeTerms(terms_),
            _encodeArgs(quote_, _buildSwapCalldata(block.chainid), dummyDelegationHash),
            singleDefaultMode,
            _encodeSingleExecution(address(mockDiamond), 0, _buildSwapCalldata(block.chainid)),
            dummyDelegationHash,
            alice,
            redeemer
        );
    }

    function test_revert_invalidDestinationChain() public {
        LiFiSwapQuoteLib.SignedLiFiQuote memory quote_ = _buildQuote(LIFI_CHAIN_ID_BTC);

        vm.prank(address(delegationManager));
        vm.expectRevert("LiFiSwapEnforcer:invalid-destination-chain");
        lifiSwapEnforcer.beforeHook(
            LiFiSwapQuoteLib.encodeTerms(_buildTerms(block.chainid)),
            _encodeArgs(quote_, _buildSwapCalldata(block.chainid), dummyDelegationHash),
            singleDefaultMode,
            _encodeSingleExecution(address(mockDiamond), 0, _buildSwapCalldata(block.chainid)),
            dummyDelegationHash,
            alice,
            redeemer
        );
    }

    function test_revertWithInvalidCallTypeMode() public {
        vm.expectRevert("CaveatEnforcer:invalid-call-type");
        lifiSwapEnforcer.beforeHook(hex"", hex"", batchDefaultMode, hex"", bytes32(0), address(0), address(0));
    }

    function test_revert_zeroQuoteSigner() public {
        LiFiSwapQuoteLib.Terms memory terms_ = _buildTerms(block.chainid);
        terms_.quoteSigner = address(0);

        LiFiSwapQuoteLib.SignedLiFiQuote memory quote_ = _buildQuote(block.chainid);
        bytes memory callData_ = _buildSwapCalldata(block.chainid);
        bytes memory execData_ = _encodeSingleExecution(address(mockDiamond), 0, callData_);
        bytes memory args_ = abi.encode(quote_, _signQuote(quoteSignerPrivateKey, quote_, dummyDelegationHash));

        vm.prank(address(delegationManager));
        vm.expectRevert("LiFiSwapEnforcer:invalid-zero-quote-signer");
        lifiSwapEnforcer.beforeHook(
            LiFiSwapQuoteLib.encodeTerms(terms_), args_, singleDefaultMode, execData_, dummyDelegationHash, alice, redeemer
        );
    }

    function test_revert_slippageBpsEqualsDenominator() public {
        LiFiSwapQuoteLib.Terms memory terms_ = _buildTerms(block.chainid);
        terms_.slippageBps = LiFiSwapQuoteLib.BPS_DENOMINATOR;

        vm.prank(address(delegationManager));
        vm.expectRevert("LiFiSwapEnforcer:invalid-slippage-bps");
        lifiSwapEnforcer.beforeHook(
            LiFiSwapQuoteLib.encodeTerms(terms_),
            _encodeArgs(_buildQuote(block.chainid), _buildSwapCalldata(block.chainid), dummyDelegationHash),
            singleDefaultMode,
            _encodeSingleExecution(address(mockDiamond), 0, _buildSwapCalldata(block.chainid)),
            dummyDelegationHash,
            alice,
            redeemer
        );
    }

    function test_revert_quoteReplayAcrossDelegations() public {
        bytes32 delegationHashA_ = keccak256("delegation-a");
        bytes32 delegationHashB_ = keccak256("delegation-b");

        LiFiSwapQuoteLib.Terms memory terms_ = _buildTerms(block.chainid);
        bytes memory callData_ = _buildSwapCalldata(block.chainid);
        bytes memory execData_ = _encodeSingleExecution(address(mockDiamond), 0, callData_);

        LiFiSwapQuoteLib.SignedLiFiQuote memory quote_ = _buildQuote(block.chainid);
        bytes memory argsForA_ = _encodeArgs(quote_, callData_, delegationHashA_);

        vm.prank(address(delegationManager));
        lifiSwapEnforcer.beforeHook(
            LiFiSwapQuoteLib.encodeTerms(terms_), argsForA_, singleDefaultMode, execData_, delegationHashA_, alice, redeemer
        );

        vm.prank(address(delegationManager));
        vm.expectRevert("LiFiSwapEnforcer:invalid-quote-signature");
        lifiSwapEnforcer.beforeHook(
            LiFiSwapQuoteLib.encodeTerms(terms_), argsForA_, singleDefaultMode, execData_, delegationHashB_, alice, redeemer
        );
    }

    function test_revert_afterHookInBatchMode() public {
        vm.expectRevert("CaveatEnforcer:invalid-call-type");
        lifiSwapEnforcer.afterHook(hex"", hex"", batchDefaultMode, hex"", bytes32(0), address(0), address(0));
    }

    ////////////////////// Integration //////////////////////

    function test_integration_sameChainSwap() public {
        bytes32 recipient_ = bytes32(uint256(uint160(alice)));
        LiFiSwapQuoteLib.Terms memory terms_ = _buildTerms(block.chainid);
        terms_.outputRecipient = recipient_;

        bytes memory swapCalldata_ = _buildSwapCalldata(block.chainid);
        LiFiSwapQuoteLib.SignedLiFiQuote memory quote_ = _buildQuote(block.chainid);
        quote_.outputRecipient = recipient_;
        quote_.calldataHash = keccak256(swapCalldata_);

        wbtc.mint(address(mockDiamond), minAmountOut);
        vm.prank(alice);
        usdc.approve(address(mockDiamond), inputAmount);

        bytes memory termsBytes_ = LiFiSwapQuoteLib.encodeTerms(terms_);

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(lifiSwapEnforcer), terms: termsBytes_ });

        Delegation memory delegation_ = Delegation({
            delegate: bob,
            delegator: alice,
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);
        caveats_[0].args = _encodeArgs(quote_, swapCalldata_, delegationHash_);
        delegation_ = signDelegation(users.alice, delegation_);

        uint256 usdcBefore_ = usdc.balanceOf(alice);
        uint256 wbtcBefore_ = wbtc.balanceOf(alice);

        Execution memory execution_ = Execution({ target: address(mockDiamond), value: 0, callData: swapCalldata_ });
        invokeDelegation_UserOp(users.bob, _singleDelegation(delegation_), execution_);

        assertEq(usdc.balanceOf(alice), usdcBefore_ - inputAmount);
        assertEq(wbtc.balanceOf(alice), wbtcBefore_ + minAmountOut);
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(lifiSwapEnforcer));
    }

    function _buildTerms(uint256 _destinationChainId) internal view returns (LiFiSwapQuoteLib.Terms memory terms_) {
        terms_ = LiFiSwapQuoteLib.Terms({
            lifiDiamond: address(mockDiamond),
            inputToken: address(usdc),
            outputAssetId: bytes32(uint256(uint160(address(wbtc)))),
            outputRecipient: bytes32(uint256(uint160(alice))),
            destinationChainId: _destinationChainId,
            quoteSigner: quoteSignerAddress,
            periodAmount: periodAmount,
            periodDuration: periodDuration,
            startDate: startDate,
            slippageBps: slippageBps
        });
    }

    function _buildQuote(uint256 _destinationChainId) internal view returns (LiFiSwapQuoteLib.SignedLiFiQuote memory quote_) {
        bytes memory swapCalldata_ = _buildSwapCalldata(block.chainid);
        quote_ = LiFiSwapQuoteLib.SignedLiFiQuote({
            delegator: alice,
            lifiDiamond: address(mockDiamond),
            inputToken: address(usdc),
            outputAssetId: bytes32(uint256(uint160(address(wbtc)))),
            outputRecipient: bytes32(uint256(uint160(alice))),
            destinationChainId: _destinationChainId,
            inputAmount: inputAmount,
            expectedAmountOut: expectedAmountOut,
            minAmountOut: minAmountOut,
            calldataHash: keccak256(swapCalldata_),
            expiration: block.timestamp + 1 hours
        });
    }

    function _buildSwapCalldata(uint256) internal view returns (bytes memory) {
        MockLiFiDiamond.SwapData memory swapData_ = MockLiFiDiamond.SwapData({
            callTo: address(wbtc),
            approveTo: address(wbtc),
            sendingAssetId: address(usdc),
            receivingAssetId: address(wbtc),
            fromAmount: inputAmount,
            callData: hex"",
            requiresDeposit: true
        });

        return abi.encodeWithSelector(
            MockLiFiDiamond.swapTokensSingleV3ERC20ToERC20.selector,
            bytes32(uint256(1)),
            "",
            "",
            payable(alice),
            minAmountOut,
            swapData_
        );
    }

    function _encodeArgs(
        LiFiSwapQuoteLib.SignedLiFiQuote memory _quote,
        bytes memory _callData,
        bytes32 _delegationHash
    )
        internal
        view
        returns (bytes memory)
    {
        _quote.calldataHash = keccak256(_callData);
        return abi.encode(_quote, _signQuote(quoteSignerPrivateKey, _quote, _delegationHash));
    }

    function _signQuote(
        uint256 _privateKey,
        LiFiSwapQuoteLib.SignedLiFiQuote memory _quote,
        bytes32 _delegationHash
    )
        internal
        view
        returns (bytes memory)
    {
        bytes32 ethSignedMessageHash_ =
            MessageHashUtils.toEthSignedMessageHash(LiFiSwapQuoteLib.hashQuote(_quote, _delegationHash));
        (uint8 v_, bytes32 r_, bytes32 s_) = vm.sign(_privateKey, ethSignedMessageHash_);
        return abi.encodePacked(r_, s_, v_);
    }

    function _encodeSingleExecution(address _target, uint256 _value, bytes memory _callData)
        internal
        pure
        returns (bytes memory)
    {
        return ExecutionLib.encodeSingle(_target, _value, _callData);
    }

    function _runBeforeHook(
        LiFiSwapQuoteLib.Terms memory _terms,
        LiFiSwapQuoteLib.SignedLiFiQuote memory _quote,
        bytes memory _callData
    )
        internal
    {
        _runBeforeHookWithExecution(
            LiFiSwapQuoteLib.encodeTerms(_terms),
            _quote,
            _encodeSingleExecution(address(mockDiamond), 0, _callData)
        );
    }

    function _runBeforeHookWithExecution(
        bytes memory _terms,
        LiFiSwapQuoteLib.SignedLiFiQuote memory _quote,
        bytes memory _execData,
        bytes memory _callData
    )
        internal
    {
        vm.prank(address(delegationManager));
        lifiSwapEnforcer.beforeHook(
            _terms,
            _encodeArgs(_quote, _callData, dummyDelegationHash),
            singleDefaultMode,
            _execData,
            dummyDelegationHash,
            alice,
            redeemer
        );
    }

    function _runBeforeHookWithExecution(
        bytes memory _terms,
        LiFiSwapQuoteLib.SignedLiFiQuote memory _quote,
        bytes memory _execData
    )
        internal
    {
        _runBeforeHookWithExecution(_terms, _quote, _execData, _sliceCallData(_execData));
    }

    function _sliceCallData(bytes memory _execData) private pure returns (bytes memory callData_) {
        require(_execData.length >= 52, "invalid exec data");
        callData_ = new bytes(_execData.length - 52);
        for (uint256 i = 0; i < callData_.length; ++i) {
            callData_[i] = _execData[i + 52];
        }
    }

    function _singleDelegation(Delegation memory _delegation) internal pure returns (Delegation[] memory delegations_) {
        delegations_ = new Delegation[](1);
        delegations_[0] = _delegation;
    }
}
