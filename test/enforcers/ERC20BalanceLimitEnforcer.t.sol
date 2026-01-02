// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { BasicERC20 } from "../utils/BasicERC20.t.sol";

import "../../src/utils/Types.sol";
import { Execution } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { ERC20BalanceLimitEnforcer } from "../../src/enforcers/ERC20BalanceLimitEnforcer.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";

contract ERC20BalanceLimitEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////////////// State //////////////////////////////
    ERC20BalanceLimitEnforcer public enforcer;
    BasicERC20 public token;
    address delegator;
    address delegate;
    address recipient;
    address dm;
    Execution transferExecution;
    bytes transferExecutionCallData;

    ////////////////////////////// Set up //////////////////////////////

    function setUp() public override {
        super.setUp();
        delegator = address(users.alice.deleGator);
        delegate = address(users.bob.deleGator);
        recipient = address(users.carol.deleGator);
        dm = address(delegationManager);
        enforcer = new ERC20BalanceLimitEnforcer();
        vm.label(address(enforcer), "ERC20 Balance Limit Enforcer");
        token = new BasicERC20(delegator, "TEST", "TEST", 0);
        vm.label(address(token), "ERC20 Test Token");
        transferExecution =
            Execution({ target: address(token), value: 0, callData: abi.encodeWithSelector(token.transfer.selector, recipient, 50) });
        transferExecutionCallData = abi.encode(transferExecution);
    }

    ////////////////////////////// Basic Functionality //////////////////////////////

    // Validates the terms get decoded correctly
    function test_decodedTheTerms() public {
        bytes memory terms_ = abi.encodePacked(false, address(token), address(recipient), uint256(100));
        (bool enforceLowerLimit_, address token_, address recipient_, uint256 amount_) = enforcer.getTermsInfo(terms_);
        assertEq(enforceLowerLimit_, false);
        assertEq(token_, address(token));
        assertEq(recipient_, address(recipient));
        assertEq(amount_, 100);
    }

    ////////////////////////////// Lower Limit Tests //////////////////////////////

    // Test 1: ERC20 token transfers are allowed if a lower limit is set and the delegators balance is above a lower threshold
    function test_allow_lowerLimit_balanceStaysAboveThreshold() public {
        // Set initial balance for delegator
        uint256 initialBalance_ = 200;
        vm.prank(delegator);
        token.mint(delegator, initialBalance_);

        // Terms: flag=true (lower limit enforcement), token, recipient, lower limit = 100
        // This means after execution, delegator's balance must be > 100
        bytes memory terms_ = abi.encodePacked(true, address(token), address(recipient), uint256(100));

        // Transfer 50 tokens (delegator balance: 200 -> 150, which is > 100)
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, transferExecutionCallData, bytes32(0), delegator, delegate);
        vm.prank(delegator);
        token.transfer(recipient, 50);
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, transferExecutionCallData, bytes32(0), delegator, delegate);

        // Verify final balance is above threshold
        assertEq(token.balanceOf(delegator), 150);
        assertTrue(token.balanceOf(delegator) > 100);
    }

    // Test 2: ERC20 token transfers are reverted if the delegators ERC20 token balance drops below the lower limit after a transfer
    function test_notAllow_lowerLimit_balanceDropsBelowThreshold() public {
        // Set initial balance for delegator
        uint256 initialBalance_ = 120;
        vm.prank(delegator);
        token.mint(delegator, initialBalance_);

        // Terms: flag=true (lower limit enforcement), token, recipient, lower limit = 100
        // This means after execution, delegator's balance must be > 100
        bytes memory terms_ = abi.encodePacked(true, address(token), address(recipient), uint256(100));

        // Transfer 50 tokens (delegator balance: 120 -> 70, which is <= 100)
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, transferExecutionCallData, bytes32(0), delegator, delegate);
        vm.prank(delegator);
        token.transfer(recipient, 50);
        vm.prank(dm);
        vm.expectRevert(bytes("ERC20BalanceLimitEnforcer:violated-lower-balance-limit"));
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, transferExecutionCallData, bytes32(0), delegator, delegate);
    }

    ////////////////////////////// Upper Limit Tests //////////////////////////////

    // Test 3: ERC20 token transfers are reverted if the delegators ERC20 token balance is above the set threshold
    function test_notAllow_upperLimit_balanceAboveThreshold() public {
        // Set initial balance for delegator above the threshold
        uint256 initialBalance_ = 150;
        vm.prank(delegator);
        token.mint(delegator, initialBalance_);

        // Terms: flag=false (upper limit enforcement), token, recipient, upper limit = 100
        // This means before execution, delegator's balance must be < 100
        bytes memory terms_ = abi.encodePacked(false, address(token), address(recipient), uint256(100));

        // beforeAllHook should revert because balance (150) is not < 100
        vm.prank(dm);
        vm.expectRevert(bytes("ERC20BalanceLimitEnforcer:exceeds-upper-balance-limit"));
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, transferExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Test 4: ERC20 token transfers are allowed if the delegators ERC20 token balance starts below an upper threshold and ends above the upper threshold after a token transfer
    function test_allow_upperLimit_balanceStartsBelowEndsAbove() public {
        // Set initial balance for delegator below the threshold
        uint256 initialBalance_ = 80;
        vm.prank(delegator);
        token.mint(delegator, initialBalance_);

        // Create execution that mints tokens to delegator (increasing balance above threshold)
        // This simulates a scenario where the execution increases the delegator's balance
        Execution memory mintExec_ = Execution({
            target: address(token),
            value: 0,
            callData: abi.encodeWithSelector(token.mint.selector, delegator, 50)
        });
        bytes memory mintExecCallData_ = abi.encode(mintExec_);

        // Terms: flag=false (upper limit enforcement), token, recipient, upper limit = 100
        // This means before execution, delegator's balance must be < 100
        bytes memory terms_ = abi.encodePacked(false, address(token), address(recipient), uint256(100));

        // beforeAllHook should pass because balance (80) is < 100
        // After minting 50 tokens, balance becomes 130 (which is > 100), but that's OK because upper limit only checks before execution
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecCallData_, bytes32(0), delegator, delegate);
        vm.prank(delegator);
        token.mint(delegator, 50);
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecCallData_, bytes32(0), delegator, delegate);

        // Verify final balance is above threshold
        assertEq(token.balanceOf(delegator), 130);
        assertTrue(token.balanceOf(delegator) > 100);
    }

    ////////////////////////////// Errors //////////////////////////////

    // Validates that the terms are well formed (exactly 73 bytes)
    function test_invalid_decodedTheTerms() public {
        bytes memory terms_;

        // Too small: missing required bytes (should be 73 bytes)
        terms_ = abi.encodePacked(false, address(token), address(recipient), uint8(100));
        vm.expectRevert(bytes("ERC20BalanceLimitEnforcer:invalid-terms-length"));
        enforcer.getTermsInfo(terms_);

        // Too large: extra bytes beyond 73.
        terms_ = abi.encodePacked(false, address(token), address(recipient), uint256(100), uint256(100));
        vm.expectRevert(bytes("ERC20BalanceLimitEnforcer:invalid-terms-length"));
        enforcer.getTermsInfo(terms_);
    }

    // Validates that an invalid token address (address(0)) reverts when calling beforeAllHook.
    function test_invalid_tokenAddress() public {
        bytes memory terms_ = abi.encodePacked(false, address(0), address(recipient), uint256(100));
        vm.expectRevert();
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, transferExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Reverts if the execution mode is invalid (not default).
    function test_revertWithInvalidExecutionMode() public {
        vm.prank(address(delegationManager));
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        enforcer.beforeAllHook(hex"", hex"", singleTryMode, hex"", bytes32(0), address(0), address(0));
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(enforcer));
    }
}
