// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {ISubscriber} from "../interfaces/ISubscriber.sol";
import {PositionConfig, PositionConfigLibrary} from "../libraries/PositionConfig.sol";
import {BipsLibrary} from "../libraries/BipsLibrary.sol";

import "../interfaces/INotifier.sol";

/// @notice Notifier is used to opt in to sending updates to external contracts about position modifications or transfers
abstract contract Notifier is INotifier {
    using BipsLibrary for uint256;
    using PositionConfigLibrary for *;

    error AlreadySubscribed(address subscriber);

    event Subscribed(uint256 tokenId, address subscriber);
    event Unsubscribed(uint256 tokenId, address subscriber);

    ISubscriber private constant NO_SUBSCRIBER = ISubscriber(address(0));

    // a percentage of the block.gaslimit denoted in BPS, used as the gas limit for subscriber calls
    // 100 bps is 1%
    // at 30M gas, the limit is 300K
    uint256 private constant BLOCK_LIMIT_BPS = 100;

    mapping(uint256 tokenId => ISubscriber subscriber) public subscriber;

    /// @dev Overridden in PositionManager
    modifier onlyIfApproved(address caller, uint256 tokenId) virtual;
    /// @dev Overridden in PositionManager
    modifier onlyValidConfig(uint256 tokenId, PositionConfig calldata config) virtual;
    /// @dev Overridden in PositionManager
    function positionConfigs() internal virtual returns (mapping(uint256 => bytes32) storage);

    /// @inheritdoc INotifier
    function subscribe(uint256 tokenId, PositionConfig calldata config, address newSubscriber, bytes memory data)
        external
        payable
        onlyIfApproved(msg.sender, tokenId)
        onlyValidConfig(tokenId, config)
    {
        // call to _subscribe will revert if the user already has a sub
        positionConfigs.setSubscribe(tokenId);

        ISubscriber _subscriber = subscriber[tokenId];

        if (_subscriber != NO_SUBSCRIBER) revert AlreadySubscribed(address(_subscriber));
        subscriber[tokenId] = ISubscriber(newSubscriber);

        ISubscriber(newSubscriber).notifySubscribe(tokenId, config, data);
        emit Subscribed(tokenId, address(newSubscriber));
    }

    /// @inheritdoc INotifier
    /// @dev Must always allow a user to unsubscribe. In the case of a malicious subscriber, a user can always unsubscribe safely, ensuring liquidity is always modifiable.
    function unsubscribe(uint256 tokenId, PositionConfig calldata config, bytes memory data)
        external
        payable
        onlyIfApproved(msg.sender, tokenId)
        onlyValidConfig(tokenId, config)
    {
        positionConfigs.setUnsubscribe(tokenId);
        ISubscriber _subscriber = subscriber[tokenId];

        uint256 subscriberGasLimit = block.gaslimit.calculatePortion(BLOCK_LIMIT_BPS);

        try _subscriber.notifyUnsubscribe{gas: subscriberGasLimit}(tokenId, config, data) {} catch {}

        delete subscriber[tokenId];
        emit Unsubscribed(tokenId, address(_subscriber));
    }

    function _notifyModifyLiquidity(uint256 tokenId, PositionConfig memory config, int256 liquidityChange) internal {
        subscriber[tokenId].notifyModifyLiquidity(tokenId, config, liquidityChange);
    }

    function _notifyTransfer(uint256 tokenId, address previousOwner, address newOwner) internal {
        subscriber[tokenId].notifyTransfer(tokenId, previousOwner, newOwner);
    }
}
