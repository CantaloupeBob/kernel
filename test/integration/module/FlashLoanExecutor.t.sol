// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {Kernel} from "src/Kernel.sol";
import {KernelUUPS} from "src/KernelUUPS.sol";
import {KernelImmutableECDSA} from "src/KernelImmutableECDSA.sol";
import {KernelFactory} from "src/KernelFactory.sol";
import {Call, Install} from "src/types/Structs.sol";
import {MODULE_TYPE_EXECUTOR} from "src/types/Constants.sol";
import {FlashLoanExecutor} from "src/executors/FlashLoanExecutor.sol";
import {LibERC7579} from "solady/accounts/LibERC7579.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {MockValidator} from "../../mock/MockValidator.sol";
import {MockERC20} from "../../mock/MockERC20.sol";
import {MockERC7399} from "../../mock/MockERC7399.sol";
import {MockFlashLoanTarget} from "../../mock/MockFlashLoanTarget.sol";
import {EntryPointLib} from "../../utils/EntryPointLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title Flash Loan Executor Integration Tests
/// @notice Exercises the executor with real Kernel, EntryPoint, and factory contracts.
contract FlashLoanExecutorIntegrationTest is Test {
    IEntryPoint ep;
    KernelFactory factory;
    KernelUUPS uups;
    KernelImmutableECDSA immutableEcdsa;
    MockValidator rootValidator;
    FlashLoanExecutor flashLoanExecutor;
    MockERC20 flashToken;
    MockERC7399 flashLoanWrapper;
    MockFlashLoanTarget flashLoanTarget;
    address payable beneficiary;

    uint256 internal constant LOAN_AMOUNT = 1 ether;
    uint256 internal constant FLASH_FEE_BPS = 100;

    function setUp() public {
        ep = EntryPointLib.deploy();
        uups = new KernelUUPS(ep);
        immutableEcdsa = new KernelImmutableECDSA(ep);
        factory = new KernelFactory(uups, immutableEcdsa);
        rootValidator = new MockValidator();
        flashLoanExecutor = new FlashLoanExecutor();
        flashToken = new MockERC20();
        flashLoanWrapper = new MockERC7399(FLASH_FEE_BPS);
        flashLoanTarget = new MockFlashLoanTarget();
        flashToken.mint(address(flashLoanWrapper), LOAN_AMOUNT);
        flashToken.mint(address(flashLoanTarget), LOAN_AMOUNT * FLASH_FEE_BPS / 10_000);
        beneficiary = payable(makeAddr("Beneficiary"));
        vm.txGasPrice(1);
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    /// @dev Deploy a new Kernel via factory, fund it, install root validator
    function _deployKernel() internal returns (Kernel kernel) {
        Install[] memory pkgs = new Install[](1);
        pkgs[0] = Install({moduleType: 1, module: address(rootValidator), moduleData: hex"", internalData: hex""});
        kernel = factory.deploy(pkgs, 0);
        vm.deal(address(kernel), 1e18);
    }

    function _installFlashLoanExecutor(Kernel kernel) internal {
        vm.prank(address(ep));
        kernel.installModule(MODULE_TYPE_EXECUTOR, address(flashLoanExecutor), abi.encode(hex"", hex""));
    }

    function _buildStrategyExecution(Kernel kernel, uint256 fee, bool repayFee)
        internal
        view
        returns (bytes32 mode, bytes memory executionCalldata)
    {
        Call[] memory calls = new Call[](2);
        calls[0] = Call({
            to: address(flashToken),
            value: 0,
            data: abi.encodeCall(ERC20.transfer, (address(flashLoanTarget), LOAN_AMOUNT))
        });
        bytes memory targetCallData;
        if (repayFee) {
            targetCallData = abi.encodeCall(
                MockFlashLoanTarget.execute, (address(flashToken), LOAN_AMOUNT, fee, abi.encode(address(kernel)))
            );
        } else {
            targetCallData = abi.encodeCall(
                MockFlashLoanTarget.executeWithoutFee,
                (address(flashToken), LOAN_AMOUNT, fee, abi.encode(address(kernel)))
            );
        }
        calls[1] = Call({to: address(flashLoanTarget), value: 0, data: targetCallData});

        mode = LibERC7579.encodeMode(bytes1(0x01), bytes1(0x00), bytes4(0), bytes22(0));
        executionCalldata = abi.encode(calls);
    }

    /// @dev Encode nonce key for root validation (vType=0x00, vId=0x00..00)
    function _rootNonce(address sender) internal view returns (uint256) {
        uint192 key = 0; // root validation, no enable flag
        return ep.getNonce(sender, key);
    }

    function _handleOps(PackedUserOperation[] memory ops) internal {
        vm.startPrank(beneficiary, beneficiary);
        ep.handleOps(ops, beneficiary);
        vm.stopPrank();
    }

    function _assertTokenTransfer(Vm.Log[] memory logs, address from, address to, uint256 amount) internal view {
        bytes32 transferEvent = keccak256("Transfer(address,address,uint256)");
        uint256 matches;

        for (uint256 i; i < logs.length; i++) {
            if (
                logs[i].emitter == address(flashToken) && logs[i].topics.length == 3
                    && logs[i].topics[0] == transferEvent && logs[i].topics[1] == bytes32(uint256(uint160(from)))
                    && logs[i].topics[2] == bytes32(uint256(uint160(to)))
            ) {
                assertEq(logs[i].data, abi.encode(amount), "token transfer amount");
                matches++;
            }
        }

        assertEq(matches, 1, "expected exactly one token transfer");
    }

    function test_flashLoanFixturesAreReady() external {
        Kernel kernel = _deployKernel();
        _installFlashLoanExecutor(kernel);

        assertTrue(kernel.isModuleInstalled(MODULE_TYPE_EXECUTOR, address(flashLoanExecutor), hex""));
        assertTrue(flashLoanExecutor.isInitialized(address(kernel)));
        assertEq(flashLoanWrapper.maxFlashLoan(address(flashToken)), LOAN_AMOUNT);

        (bytes32 mode, bytes memory executionCalldata) = _buildStrategyExecution(kernel, 0, true);
        Call[] memory calls = abi.decode(executionCalldata, (Call[]));
        assertEq(mode, LibERC7579.encodeMode(bytes1(0x01), bytes1(0x00), bytes4(0), bytes22(0)));
        assertEq(calls.length, 2);
        assertEq(calls[0].to, address(flashToken));
        assertEq(calls[1].to, address(flashLoanTarget));
    }

    function test_flashLoanExecutor() external {
        Kernel kernel = _deployKernel();
        _installFlashLoanExecutor(kernel);

        uint256 fee = flashLoanWrapper.flashFee(address(flashToken), LOAN_AMOUNT);
        assertEq(flashToken.balanceOf(address(flashLoanWrapper)), LOAN_AMOUNT);
        assertEq(flashToken.balanceOf(address(flashLoanTarget)), fee);
        assertEq(flashToken.balanceOf(address(flashLoanExecutor)), 0);

        (bytes32 strategyMode, bytes memory executionCalldata) = _buildStrategyExecution(kernel, fee, true);
        PackedUserOperation memory op = PackedUserOperation({
            sender: address(kernel),
            nonce: _rootNonce(address(kernel)),
            initCode: hex"",
            callData: abi.encodeWithSelector(
                Kernel.execute.selector,
                bytes32(0),
                abi.encodePacked(
                    address(flashLoanExecutor),
                    uint256(0),
                    abi.encodeCall(
                        FlashLoanExecutor.flash,
                        (address(flashLoanWrapper), address(flashToken), LOAN_AMOUNT, strategyMode, executionCalldata)
                    )
                )
            ),
            accountGasLimits: bytes32(abi.encodePacked(uint128(2_000_000), uint128(2_000_000))),
            preVerificationGas: 1_000_000,
            gasFees: bytes32(abi.encodePacked(uint128(1), uint128(1))),
            paymasterAndData: hex"",
            signature: hex""
        });

        rootValidator.sudoSetSuccess(true);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        vm.recordLogs();
        _handleOps(ops);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 flashLoanEvent = keccak256("FlashLoanReceived(address,uint256,uint256,address)");
        bytes32 userOperationEvent =
            keccak256("UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)");
        bool receivedFlashLoanEvent;
        bool userOperationSucceeded;
        for (uint256 i; i < logs.length; i++) {
            if (
                logs[i].emitter == address(flashLoanTarget) && logs[i].topics.length > 0
                    && logs[i].topics[0] == flashLoanEvent
            ) {
                assertFalse(receivedFlashLoanEvent, "flash-loan target emitted duplicate receipt events");
                assertEq(logs[i].data, abi.encode(address(flashToken), LOAN_AMOUNT, fee, address(kernel)), "event data");
                receivedFlashLoanEvent = true;
            }

            if (logs[i].emitter == address(ep) && logs[i].topics.length == 4 && logs[i].topics[0] == userOperationEvent)
            {
                assertFalse(userOperationSucceeded, "entry point emitted duplicate operation events");
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(address(kernel)))), "operation sender");
                (uint256 nonce, bool success,,) = abi.decode(logs[i].data, (uint256, bool, uint256, uint256));
                assertEq(nonce, op.nonce, "operation nonce");
                assertTrue(success, "entry point reported failed user operation");
                userOperationSucceeded = true;
            }
        }
        assertTrue(receivedFlashLoanEvent, "flash-loan target receipt event not emitted");
        assertTrue(userOperationSucceeded, "entry point operation event not emitted");

        _assertTokenTransfer(logs, address(flashLoanWrapper), address(kernel), LOAN_AMOUNT);
        _assertTokenTransfer(logs, address(kernel), address(flashLoanTarget), LOAN_AMOUNT);
        _assertTokenTransfer(logs, address(flashLoanTarget), address(kernel), LOAN_AMOUNT + fee);
        _assertTokenTransfer(logs, address(kernel), address(flashLoanWrapper), LOAN_AMOUNT + fee);

        bytes[] memory expectedResults = new bytes[](2);
        expectedResults[0] = abi.encode(true);
        expectedResults[1] = abi.encode(address(flashToken), LOAN_AMOUNT, fee, address(kernel));
        assertEq(flashLoanWrapper.lastResult(), abi.encode(expectedResults), "callback return data");
        assertEq(flashToken.balanceOf(address(flashLoanWrapper)), LOAN_AMOUNT + fee);
        assertEq(flashToken.balanceOf(address(flashLoanExecutor)), 0);
        assertEq(flashToken.balanceOf(address(flashLoanTarget)), 0);
        assertEq(flashToken.balanceOf(address(kernel)), 0);
        assertEq(flashLoanTarget.data(address(kernel)), 1);
    }

    function test_flashRejectsCallerWithoutInstalledAccount() external {
        vm.prank(makeAddr("uninstalled account"));
        vm.expectRevert(FlashLoanExecutor.Unauthorized.selector);
        flashLoanExecutor.flash(address(flashLoanWrapper), address(flashToken), LOAN_AMOUNT, bytes32(0), hex"");

        assertEq(flashToken.balanceOf(address(flashLoanWrapper)), LOAN_AMOUNT);
        assertEq(flashToken.balanceOf(address(flashLoanTarget)), LOAN_AMOUNT * FLASH_FEE_BPS / 10_000);
    }

    function test_onFlashLoanRejectsCallOutsideFlashContext() external {
        vm.expectRevert(FlashLoanExecutor.Unauthorized.selector);
        flashLoanExecutor.onFlashLoan(
            address(flashLoanExecutor),
            address(flashLoanWrapper),
            address(flashToken),
            LOAN_AMOUNT,
            0,
            abi.encode(address(0), address(flashLoanWrapper), bytes32(0), hex"")
        );

        assertEq(flashToken.balanceOf(address(flashLoanWrapper)), LOAN_AMOUNT);
        assertEq(flashToken.balanceOf(address(flashLoanExecutor)), 0);
    }

    function test_lifecycleCallbacksCannotFakeRegistryInstallation() external {
        address caller = makeAddr("uninstalled account");

        vm.prank(caller);
        flashLoanExecutor.onInstall(hex"");
        assertFalse(flashLoanExecutor.isInitialized(caller));

        vm.prank(caller);
        flashLoanExecutor.onUninstall(hex"");
        assertFalse(flashLoanExecutor.isInitialized(caller));

        vm.prank(caller);
        vm.expectRevert(FlashLoanExecutor.Unauthorized.selector);
        flashLoanExecutor.flash(address(flashLoanWrapper), address(flashToken), LOAN_AMOUNT, bytes32(0), hex"");
    }

    function test_uninstallRevokesFlashLoanAccess() external {
        Kernel kernel = _deployKernel();
        _installFlashLoanExecutor(kernel);
        assertTrue(flashLoanExecutor.isInitialized(address(kernel)));

        vm.prank(address(ep));
        kernel.uninstallModule(MODULE_TYPE_EXECUTOR, address(flashLoanExecutor), abi.encode(hex"", hex""));

        assertFalse(kernel.isModuleInstalled(MODULE_TYPE_EXECUTOR, address(flashLoanExecutor), hex""));
        assertFalse(flashLoanExecutor.isInitialized(address(kernel)));

        vm.prank(address(kernel));
        vm.expectRevert(FlashLoanExecutor.Unauthorized.selector);
        flashLoanExecutor.flash(address(flashLoanWrapper), address(flashToken), LOAN_AMOUNT, bytes32(0), hex"");
    }

    function test_flashRejectsUnexpectedCallbackInitiator() external {
        Kernel kernel = _deployKernel();
        _installFlashLoanExecutor(kernel);
        flashLoanWrapper.setCallbackInitiatorOverride(makeAddr("unexpected initiator"));
        uint256 fee = flashLoanWrapper.flashFee(address(flashToken), LOAN_AMOUNT);
        (bytes32 mode, bytes memory executionCalldata) = _buildStrategyExecution(kernel, fee, true);

        vm.prank(address(kernel));
        vm.expectRevert(FlashLoanExecutor.Unauthorized.selector);
        flashLoanExecutor.flash(address(flashLoanWrapper), address(flashToken), LOAN_AMOUNT, mode, executionCalldata);

        assertEq(flashToken.balanceOf(address(flashLoanWrapper)), LOAN_AMOUNT);
        assertEq(flashToken.balanceOf(address(flashLoanExecutor)), 0);
        assertEq(flashToken.balanceOf(address(flashLoanTarget)), LOAN_AMOUNT * FLASH_FEE_BPS / 10_000);
    }

    function test_lenderRevertsWhenCallbackAmountLeavesLoanUnrepaid() external {
        Kernel kernel = _deployKernel();
        _installFlashLoanExecutor(kernel);
        flashLoanWrapper.setCallbackAmountOverride(LOAN_AMOUNT - 1);
        uint256 fee = flashLoanWrapper.flashFee(address(flashToken), LOAN_AMOUNT);
        (bytes32 mode, bytes memory executionCalldata) = _buildStrategyExecution(kernel, fee, true);

        vm.prank(address(kernel));
        vm.expectRevert(MockERC7399.InsufficientRepayment.selector);
        flashLoanExecutor.flash(address(flashLoanWrapper), address(flashToken), LOAN_AMOUNT, mode, executionCalldata);

        assertEq(flashToken.balanceOf(address(flashLoanWrapper)), LOAN_AMOUNT);
        assertEq(flashToken.balanceOf(address(flashLoanExecutor)), 0);
        assertEq(flashToken.balanceOf(address(flashLoanTarget)), fee);
        assertEq(flashToken.balanceOf(address(kernel)), 0);
        assertEq(flashLoanTarget.data(address(kernel)), 0);
        assertEq(flashLoanWrapper.lastResult(), hex"");
    }

    function test_flashRevertsWhenAmountExceedsLiquidity() external {
        Kernel kernel = _deployKernel();
        _installFlashLoanExecutor(kernel);

        vm.prank(address(kernel));
        vm.expectRevert(FlashLoanExecutor.InsufficientLiquidity.selector);
        flashLoanExecutor.flash(address(flashLoanWrapper), address(flashToken), LOAN_AMOUNT + 1, bytes32(0), hex"");

        assertEq(flashToken.balanceOf(address(flashLoanWrapper)), LOAN_AMOUNT);
        assertEq(flashToken.balanceOf(address(flashLoanExecutor)), 0);
        assertEq(flashToken.balanceOf(address(flashLoanTarget)), LOAN_AMOUNT * FLASH_FEE_BPS / 10_000);
    }

    function test_flashRevertsWhenTargetCallFails() external {
        Kernel kernel = _deployKernel();
        _installFlashLoanExecutor(kernel);
        uint256 fee = flashLoanWrapper.flashFee(address(flashToken), LOAN_AMOUNT);
        bytes memory executionCalldata = abi.encodePacked(
            address(flashLoanTarget),
            uint256(0),
            abi.encodeCall(
                MockFlashLoanTarget.execute, (address(flashToken), LOAN_AMOUNT, fee, abi.encode(address(kernel)))
            )
        );

        vm.prank(address(kernel));
        vm.expectRevert(MockFlashLoanTarget.FLNotReceived.selector);
        flashLoanExecutor.flash(
            address(flashLoanWrapper), address(flashToken), LOAN_AMOUNT, bytes32(0), executionCalldata
        );

        assertEq(flashToken.balanceOf(address(flashLoanWrapper)), LOAN_AMOUNT);
        assertEq(flashToken.balanceOf(address(flashLoanExecutor)), 0);
        assertEq(flashToken.balanceOf(address(flashLoanTarget)), LOAN_AMOUNT * FLASH_FEE_BPS / 10_000);
    }

    function test_flashRevertsWhenTargetDoesNotRepayFee() external {
        Kernel kernel = _deployKernel();
        _installFlashLoanExecutor(kernel);
        uint256 fee = flashLoanWrapper.flashFee(address(flashToken), LOAN_AMOUNT);
        (bytes32 mode, bytes memory executionCalldata) = _buildStrategyExecution(kernel, fee, false);

        vm.prank(address(kernel));
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        flashLoanExecutor.flash(address(flashLoanWrapper), address(flashToken), LOAN_AMOUNT, mode, executionCalldata);

        assertEq(flashToken.balanceOf(address(flashLoanWrapper)), LOAN_AMOUNT);
        assertEq(flashToken.balanceOf(address(flashLoanExecutor)), 0);
        assertEq(flashToken.balanceOf(address(kernel)), 0);
        assertEq(flashToken.balanceOf(address(flashLoanTarget)), fee);
        assertEq(flashLoanTarget.data(address(kernel)), 0);
        assertEq(flashLoanWrapper.lastResult(), hex"");
    }
}
