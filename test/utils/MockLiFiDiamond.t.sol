// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockLiFiDiamond
 * @notice Minimal LiFi Diamond mock for LiFiSwapEnforcer tests.
 */
contract MockLiFiDiamond {
    using SafeERC20 for IERC20;

    struct SwapData {
        address callTo;
        address approveTo;
        address sendingAssetId;
        address receivingAssetId;
        uint256 fromAmount;
        bytes callData;
        bool requiresDeposit;
    }

    function swapTokensSingleV3ERC20ToERC20(
        bytes32,
        string calldata,
        string calldata,
        address payable _receiver,
        uint256 _minAmountOut,
        SwapData calldata _swapData
    )
        external
    {
        IERC20 sendingAsset_ = IERC20(_swapData.sendingAssetId);
        IERC20 receivingAsset_ = IERC20(_swapData.receivingAssetId);

        sendingAsset_.safeTransferFrom(msg.sender, address(this), _swapData.fromAmount);

        uint256 amountReceived_ = receivingAsset_.balanceOf(address(this));
        if (amountReceived_ < _minAmountOut) {
            revert("MockLiFiDiamond:slippage-too-high");
        }

        receivingAsset_.safeTransfer(_receiver, amountReceived_);
    }

    function execute(bytes calldata) external pure {
        return;
    }

    function depositOutputToken(address _token, uint256 _amount) external {
        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
    }
}
