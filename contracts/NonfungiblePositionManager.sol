// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ERC721Permit} from "./base/ERC721Permit.sol";
import {INonfungiblePositionManager} from "./interfaces/INonfungiblePositionManager.sol";
import {BaseLiquidityManagement} from "./base/BaseLiquidityManagement.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettleTake} from "./libraries/CurrencySettleTake.sol";
import {LiquidityRange, LiquidityRangeId, LiquidityRangeIdLibrary} from "./types/LiquidityRange.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {LiquidityAmounts} from "./libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {TransientLiquidityDelta} from "./libraries/TransientLiquidityDelta.sol";
import {TransientState} from "./libraries/TransientState.sol";

import "forge-std/console2.sol";

contract NonfungiblePositionManager is INonfungiblePositionManager, BaseLiquidityManagement, ERC721Permit {
    using CurrencyLibrary for Currency;
    using CurrencySettleTake for Currency;
    using PoolIdLibrary for PoolKey;
    using LiquidityRangeIdLibrary for LiquidityRange;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using SafeCast for uint256;
    using TransientLiquidityDelta for Currency;

    /// @dev The ID of the next token that will be minted. Skips 0
    uint256 public nextTokenId = 1;

    // maps the ERC721 tokenId to the keys that uniquely identify a liquidity position (owner, range)
    mapping(uint256 tokenId => TokenPosition position) public tokenPositions;

    // TODO: TSTORE these jawns
    bool internal unlockedByThis;

    constructor(IPoolManager _manager)
        BaseLiquidityManagement(_manager)
        ERC721Permit("Uniswap V4 Positions NFT-V1", "UNI-V4-POS", "1")
    {}

    function unlockAndExecute(bytes[] memory data, Currency[] memory currencies)
        public
        returns (int128[] memory finalDeltas)
    {
        TransientState.storeMsgSender(); // @todo: fix! If someone reenters, msgSender will change, and will not reset to the old msgSender.
        finalDeltas = abi.decode(manager.unlock(abi.encode(data, currencies)), (int128[]));
        TransientState.storeUnlock(false);
        // Need to make sure transient is cleared;
    }

    function _unlockCallback(bytes calldata payload) internal override returns (bytes memory) {
        TransientState.storeUnlock(true);
        (bytes[] memory data, Currency[] memory currencies) = abi.decode(payload, (bytes[], Currency[]));

        bool success;

        for (uint256 i; i < data.length; i++) {
            // TODO: bubble up the return
            (success,) = address(this).call(data[i]);
            if (!success) revert("EXECUTE_FAILED");
        }

        // close the deltas
        int128[] memory returnData = new int128[](currencies.length);
        for (uint256 i; i < currencies.length; i++) {
            returnData[i] = currencies[i].close(manager, _msgSender());
            currencies[i].close(manager, address(this));
        }

        return abi.encode(returnData);
    }

    function mint(
        LiquidityRange calldata range,
        uint256 liquidity,
        uint256 deadline,
        address owner,
        bytes calldata hookData
    ) external payable onlyIfUnlocked checkDeadline(deadline) {
        _increaseLiquidity(owner, _msgSender(), range, liquidity, hookData);

        // mint receipt token
        uint256 tokenId;
        _mint(owner, (tokenId = nextTokenId++));
        tokenPositions[tokenId] = TokenPosition({owner: owner, range: range});
    }

    function increaseLiquidity(
        uint256 tokenId,
        uint256 liquidity,
        uint256 deadline,
        bytes calldata hookData,
        bool claims
    ) external isAuthorizedForToken(tokenId) onlyIfUnlocked checkDeadline(deadline) {
        TokenPosition memory tokenPos = tokenPositions[tokenId];
        _increaseLiquidity(tokenPos.owner, _msgSender(), tokenPos.range, liquidity, hookData);
    }

    function decreaseLiquidity(
        uint256 tokenId,
        uint256 liquidity,
        uint256 deadline,
        bytes calldata hookData,
        bool claims
    ) external isAuthorizedForToken(tokenId) onlyIfUnlocked checkDeadline(deadline) {
        TokenPosition memory tokenPos = tokenPositions[tokenId];
        _decreaseLiquidity(tokenPos.owner, tokenPos.range, liquidity, hookData);
    }

    function burn(uint256 tokenId) public isAuthorizedForToken(tokenId) {
        // TODO: Burn currently requires a decrease and collect call before the token can be deleted. Possible to combine.
        // We do not need to enforce the pool manager to be unlocked bc this function is purely clearing storage for the minted tokenId.
        TokenPosition memory tokenPos = tokenPositions[tokenId];
        // Checks that the full position's liquidity has been removed and all tokens have been collected from tokensOwed.
        _validateBurn(tokenPos.owner, tokenPos.range);
        delete tokenPositions[tokenId];
        // Burn the token.
        _burn(tokenId);
    }

    // TODO: In v3, we can partially collect fees. Can potentially allow that. Or separate collect underlying fees (pm) from collect all tokens(posm).
    function collect(uint256 tokenId, address recipient, bytes calldata hookData, bool claims)
        external
        onlyIfUnlocked
    {
        TokenPosition memory tokenPos = tokenPositions[tokenId];
        _collect(recipient, tokenPos.owner, _msgSender(), tokenPos.range, hookData);
    }

    function feesOwed(uint256 tokenId) external view returns (uint256 token0Owed, uint256 token1Owed) {
        TokenPosition memory tokenPosition = tokenPositions[tokenId];
        return feesOwed(tokenPosition.owner, tokenPosition.range);
    }

    function _beforeTokenTransfer(address from, address to, uint256 tokenId) internal override {
        TokenPosition storage tokenPosition = tokenPositions[tokenId];
        LiquidityRangeId rangeId = tokenPosition.range.toId();
        Position storage position = positions[from][rangeId];
        position.operator = address(0x0);

        // transfer position data to destination
        positions[to][rangeId] = position;
        delete positions[from][rangeId];

        // update token position
        tokenPositions[tokenId] = TokenPosition({owner: to, range: tokenPosition.range});
    }

    function _getAndIncrementNonce(uint256 tokenId) internal override returns (uint256) {
        TokenPosition memory tokenPosition = tokenPositions[tokenId];
        return uint256(positions[tokenPosition.owner][tokenPosition.range.toId()].nonce++);
    }

    modifier isAuthorizedForToken(uint256 tokenId) {
        require(msg.sender == address(this) || _isApprovedOrOwner(msg.sender, tokenId), "Not approved");
        _;
    }

    /// @notice This just ensures the original unlock on the pool manager was called by this contract.
    modifier onlyIfUnlocked() {
        if (!TransientState.loadUnlock()) revert MustBeUnlockedByThisContract();
        _;
    }

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert DeadlinePassed();
        _;
    }

    function _msgSender() internal view override returns (address) {
        return TransientState.loadMsgSender();
    }
}
