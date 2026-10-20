// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC20} from "solady/tokens/ERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

contract MockFlashLoanTarget {
    using SafeTransferLib for address;

    error FLNotReceived();

    event FlashLoanReceived(address token, uint256 flAmount, uint256 flFee, address account);

    mapping(address account => uint256) public data;

    function execute(address token, uint256 amount, uint256 fee, bytes memory callData)
        external
        returns (address, uint256, uint256, address)
    {
        return _execute(token, amount, fee, callData, amount + fee);
    }

    function executeWithoutFee(address token, uint256 amount, uint256 fee, bytes memory callData)
        external
        returns (address, uint256, uint256, address)
    {
        return _execute(token, amount, fee, callData, amount);
    }

    function _execute(address token, uint256 amount, uint256 fee, bytes memory callData, uint256 repayment)
        private
        returns (address, uint256, uint256, address)
    {
        require(token.balanceOf(address(this)) == amount + fee, FLNotReceived());
        address account = abi.decode(callData, (address));
        data[account] = 1;
        token.safeTransfer(msg.sender, repayment);

        emit FlashLoanReceived(token, amount, fee, account);
        return (token, amount, fee, account);
    }
}
