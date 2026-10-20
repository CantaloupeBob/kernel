// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC7399} from "src/executors/interfaces/IERC7399.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

contract MockERC7399 is IERC7399 {
    using SafeTransferLib for address;

    error InsufficientLiquidity();
    error InsufficientRepayment();

    uint256 public immutable feeBps;
    bytes public lastResult;
    address public callbackInitiatorOverride;
    bool public repeatCallback;
    uint256 public callbackAmountOverride;

    constructor(uint256 feeBps_) {
        feeBps = feeBps_;
    }

    function maxFlashLoan(address asset) external view override returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function flashFee(address, uint256 amount) external view override returns (uint256) {
        return amount * feeBps / 10_000;
    }

    function setCallbackInitiatorOverride(address initiator) external {
        callbackInitiatorOverride = initiator;
    }

    function setRepeatCallback(bool repeatCallback_) external {
        repeatCallback = repeatCallback_;
    }

    function setCallbackAmountOverride(uint256 amount) external {
        callbackAmountOverride = amount;
    }

    function flash(
        address loanReceiver,
        address asset,
        uint256 amount,
        bytes calldata data,
        function(address, address, address, uint256, uint256, bytes memory) external returns (bytes memory) callback
    ) external override returns (bytes memory result) {
        uint256 balanceBefore = asset.balanceOf(address(this));
        if (balanceBefore < amount) revert InsufficientLiquidity();

        uint256 fee = amount * feeBps / 10_000;
        address initiator = callbackInitiatorOverride == address(0) ? msg.sender : callbackInitiatorOverride;
        uint256 callbackAmount = callbackAmountOverride == 0 ? amount : callbackAmountOverride;
        asset.safeTransfer(loanReceiver, amount);
        result = callback(initiator, address(this), asset, callbackAmount, fee, data);
        if (repeatCallback) callback(initiator, address(this), asset, callbackAmount, fee, data);
        lastResult = result;

        if (asset.balanceOf(address(this)) < balanceBefore + fee) {
            revert InsufficientRepayment();
        }
    }
}
