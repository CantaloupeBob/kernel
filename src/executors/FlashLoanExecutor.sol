// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IExecutor} from "src/interfaces/IERC7579Modules.sol";
import {IERC7579Account} from "src/interfaces/IERC7579Account.sol";
import {IERC7399} from "src/executors/interfaces/IERC7399.sol";
import {MODULE_TYPE_EXECUTOR} from "../types/Constants.sol";
import {LibERC7579} from "solady/accounts/LibERC7579.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title FlashLoanExecutor
/// @notice Executes ERC-7399 flashloans for accounts that have installed this executor.
contract FlashLoanExecutor is IExecutor, ReentrancyGuardTransient {
    /// @dev The caller is not an installed account or the callback context is invalid.
    error Unauthorized();

    /// @dev The lender cannot provide the requested loan amount.
    error InsufficientLiquidity();

    /// @dev The lender did not invoke the callback exactly once.
    error InvalidCallback();

    /// @dev This contract.
    address private immutable _SELF;

    /// @dev Hash of the expected callback payload; zero means no callback is pending.
    bytes32 private transient _callbackDataHash;


    constructor() {
        _SELF = address(this);
    }

    /// @notice Requests an ERC-7399 flashloan for an installed smart account.
    /// @dev The loan is delivered to the account. Callback data binds the account, lender, and strategy,
    ///      and the strategy is executed by the account through `executeFromExecutor`.
    /// @param flWrapper ERC-7399 lender to use for the loan.
    /// @param flToken Token to borrow.
    /// @param flAmount Principal amount to borrow.
    /// @param mode ERC-7579 execution mode for the account's loan strategy.
    /// @param executionCalldata Encoded account execution data matching `mode`.
    /// @return Encoded return data from the account's strategy calls.
    function flash(address flWrapper, address flToken, uint256 flAmount, bytes32 mode, bytes calldata executionCalldata)
        external
        nonReentrant
        returns (bytes memory)
    {
        require(_isInstalledAccount(msg.sender), Unauthorized());
        IERC7399 flw = IERC7399(flWrapper);
        require(flw.maxFlashLoan(flToken) >= flAmount, InsufficientLiquidity());

        bytes memory callbackData = abi.encode(msg.sender, flWrapper, mode, executionCalldata);
        _callbackDataHash = keccak256(callbackData);
        bytes memory result = flw.flash(msg.sender, flToken, flAmount, callbackData, this.onFlashLoan);

        require(_callbackDataHash == bytes32(0), InvalidCallback());
        return result;
    }

    /// @notice Executes the account's flashloan strategy and repays the lender-designated receiver.
    /// @dev This callback runs inside the guarded `flash` call, so it authenticates the lender and payload
    ///      instead of applying the reentrancy guard a second time.
    /// @param initiator Address that initiated the lender call; must be this executor.
    /// @param paymentReceiver Address that must receive the principal and fee.
    /// @param flToken Token borrowed from the lender.
    /// @param flAmount Principal amount borrowed.
    /// @param flFee Fee owed to the lender.
    /// @param callbackData ABI-encoded `(account, lender, mode, executionCalldata)` tuple.
    /// @return Encoded return data from the account's strategy calls.
    function onFlashLoan(
        address initiator,
        address paymentReceiver,
        address flToken,
        uint256 flAmount,
        uint256 flFee,
        bytes memory callbackData
    ) external returns (bytes memory) {
        require(initiator == address(this), Unauthorized());
        (address accountAddress, address flWrapper, bytes32 mode, bytes memory executionCalldata) =
            abi.decode(callbackData, (address, address, bytes32, bytes));
        require(msg.sender == flWrapper, Unauthorized());
        require(keccak256(callbackData) == _callbackDataHash, Unauthorized());

        _callbackDataHash = bytes32(0);

        IERC7579Account account = IERC7579Account(accountAddress);
        bytes[] memory results = account.executeFromExecutor(mode, executionCalldata);

        account.executeFromExecutor(
            LibERC7579.encodeMode(LibERC7579.CALLTYPE_DELEGATECALL, LibERC7579.EXECTYPE_DEFAULT, bytes4(0), bytes22(0)),
            abi.encodePacked(
                address(this), abi.encodeCall(this.safeTransferForAccount, (flToken, paymentReceiver, flAmount + flFee))
            )
        );

        return abi.encode(results);
    }

    /// @dev Intended for the account's delegatecall path so the transfer originates from the account.
    function safeTransferForAccount(address token, address to, uint256 amount) external {
        require(address(this) != _SELF && msg.sender == _SELF, Unauthorized());
        SafeTransferLib.safeTransfer(token, to, amount);
    }

    /// @notice Handles the ERC-7579 installation callback.
    /// @dev The Kernel executor registry is the source of truth; no module-local state is needed.
    function onInstall(bytes calldata) external payable override {
        // No-op: the Kernel registry records the installation after this callback succeeds.
    }

    /// @notice Handles the ERC-7579 uninstallation callback.
    /// @dev No module-local state is changed, so direct calls cannot grant or revoke executor authority.
    function onUninstall(bytes calldata) external payable override {
        // No-op: the Kernel registry revokes the executor before this callback.
    }

    /// @notice Returns whether this executor is installed for a smart account.
    /// @param smartAccount Smart account to check.
    /// @return True if the account has installed this executor.
    function isInitialized(address smartAccount) external view override returns (bool) {
        return _isInstalledAccount(smartAccount);
    }

    /// @notice Returns whether this module implements the executor module type.
    /// @param moduleTypeId Module type identifier to check.
    /// @return True only when `moduleTypeId` is the executor module type.
    function isModuleType(uint256 moduleTypeId) external pure override returns (bool) {
        return moduleTypeId == MODULE_TYPE_EXECUTOR;
    }

    function _isInstalledAccount(address account) internal view returns (bool) {
        return account.code.length != 0
            && IERC7579Account(account).isModuleInstalled(MODULE_TYPE_EXECUTOR, address(this), hex"");
    }
}
