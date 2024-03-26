// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {LiquidityAmounts} from "../../contracts/libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import {INonfungiblePositionManager} from "../../contracts/interfaces/INonfungiblePositionManager.sol";
import {NonfungiblePositionManager} from "../../contracts/NonfungiblePositionManager.sol";
import {LiquidityRange, LiquidityRangeId, LiquidityRangeIdLibrary} from "../../contracts/types/LiquidityRange.sol";

import {LiquidityFuzzers} from "../shared/fuzz/LiquidityFuzzers.sol";

contract FeeCollectionTest is Test, Deployers, GasSnapshot, LiquidityFuzzers {
    using FixedPointMathLib for uint256;
    using CurrencyLibrary for Currency;
    using LiquidityRangeIdLibrary for LiquidityRange;

    NonfungiblePositionManager lpm;

    PoolId poolId;
    address alice = makeAddr("ALICE");
    address bob = makeAddr("BOB");

    // unused value for the fuzz helper functions
    uint128 constant DEAD_VALUE = 6969.6969 ether;

    function setUp() public {
        Deployers.deployFreshManagerAndRouters();
        Deployers.deployMintAndApprove2Currencies();

        (key, poolId) = initPool(currency0, currency1, IHooks(address(0)), 3000, SQRT_RATIO_1_1, ZERO_BYTES);

        lpm = new NonfungiblePositionManager(manager);
        IERC20(Currency.unwrap(currency0)).approve(address(lpm), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(lpm), type(uint256).max);

        // Give tokens to Alice and Bob, with approvals
        IERC20(Currency.unwrap(currency0)).transfer(alice, 10_000_000 ether);
        IERC20(Currency.unwrap(currency1)).transfer(alice, 10_000_000 ether);
        IERC20(Currency.unwrap(currency0)).transfer(bob, 10_000_000 ether);
        IERC20(Currency.unwrap(currency1)).transfer(bob, 10_000_000 ether);
        vm.startPrank(alice);
        IERC20(Currency.unwrap(currency0)).approve(address(lpm), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(lpm), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(bob);
        IERC20(Currency.unwrap(currency0)).approve(address(lpm), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(lpm), type(uint256).max);
        vm.stopPrank();
    }

    function test_collect_6909(int24 tickLower, int24 tickUpper, uint128 liquidityDelta) public {
        uint256 tokenId;
        liquidityDelta = uint128(bound(liquidityDelta, 100e18, 100_000e18)); // require nontrivial amount of liquidity
        (tokenId, tickLower, tickUpper, liquidityDelta,) =
            createFuzzyLiquidity(lpm, address(this), key, tickLower, tickUpper, liquidityDelta, ZERO_BYTES);
        vm.assume(tickLower < -60 && 60 < tickUpper); // require two-sided liquidity

        // swap to create fees
        uint256 swapAmount = 0.01e18;
        swap(key, false, int256(swapAmount), ZERO_BYTES);

        // collect fees
        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();
        BalanceDelta delta = lpm.collect(tokenId, address(this), ZERO_BYTES, true);

        assertEq(delta.amount0(), 0);

        // express key.fee as wad (i.e. 3000 = 0.003e18)
        uint256 feeWad = uint256(key.fee).mulDivDown(FixedPointMathLib.WAD, 1_000_000);
        assertApproxEqAbs(uint256(int256(delta.amount1())), swapAmount.mulWadDown(feeWad), 1 wei);

        assertEq(uint256(int256(delta.amount1())), manager.balanceOf(address(this), currency1.toId()));
    }

    function test_collect_erc20(int24 tickLower, int24 tickUpper, uint128 liquidityDelta) public {
        uint256 tokenId;
        liquidityDelta = uint128(bound(liquidityDelta, 100e18, 100_000e18)); // require nontrivial amount of liquidity
        (tokenId, tickLower, tickUpper, liquidityDelta,) =
            createFuzzyLiquidity(lpm, address(this), key, tickLower, tickUpper, liquidityDelta, ZERO_BYTES);
        vm.assume(tickLower < -60 && 60 < tickUpper); // require two-sided liquidity

        // swap to create fees
        uint256 swapAmount = 0.01e18;
        swap(key, false, int256(swapAmount), ZERO_BYTES);

        // collect fees
        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();
        BalanceDelta delta = lpm.collect(tokenId, address(this), ZERO_BYTES, false);

        assertEq(delta.amount0(), 0);

        // express key.fee as wad (i.e. 3000 = 0.003e18)
        uint256 feeWad = uint256(key.fee).mulDivDown(FixedPointMathLib.WAD, 1_000_000);
        assertApproxEqAbs(uint256(int256(delta.amount1())), swapAmount.mulWadDown(feeWad), 1 wei);

        assertEq(uint256(int256(delta.amount1())), currency1.balanceOfSelf() - balance1Before);
    }

    // two users with the same range; one user cannot collect the other's fees
    function test_collect_sameRange_6909(
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidityDeltaAlice,
        uint128 liquidityDeltaBob
    ) public {
        uint256 tokenIdAlice;
        uint256 tokenIdBob;
        liquidityDeltaAlice = uint128(bound(liquidityDeltaAlice, 100e18, 100_000e18)); // require nontrivial amount of liquidity
        liquidityDeltaBob = uint128(bound(liquidityDeltaBob, 100e18, 100_000e18));

        (tickLower, tickUpper, liquidityDeltaAlice) =
            createFuzzyLiquidityParams(key, tickLower, tickUpper, liquidityDeltaAlice);
        vm.assume(tickLower < -60 && 60 < tickUpper); // require two-sided liquidity
        (,, liquidityDeltaBob) = createFuzzyLiquidityParams(key, tickLower, tickUpper, liquidityDeltaBob);

        vm.prank(alice);
        (tokenIdAlice,) = lpm.mint(
            LiquidityRange({key: key, tickLower: tickLower, tickUpper: tickUpper}),
            liquidityDeltaAlice,
            block.timestamp + 1,
            alice,
            ZERO_BYTES
        );

        vm.prank(bob);
        (tokenIdBob,) = lpm.mint(
            LiquidityRange({key: key, tickLower: tickLower, tickUpper: tickUpper}),
            liquidityDeltaBob,
            block.timestamp + 1,
            alice,
            ZERO_BYTES
        );

        // swap to create fees
        uint256 swapAmount = 0.01e18;
        swap(key, false, int256(swapAmount), ZERO_BYTES);

        // alice collects only her fees
        vm.prank(alice);
        BalanceDelta delta = lpm.collect(tokenIdAlice, alice, ZERO_BYTES, true);
        assertEq(uint256(uint128(delta.amount0())), manager.balanceOf(alice, currency0.toId()));
        assertEq(uint256(uint128(delta.amount1())), manager.balanceOf(alice, currency1.toId()));
        assertTrue(delta.amount1() != 0);

        // bob collects only his fees
        vm.prank(bob);
        delta = lpm.collect(tokenIdBob, bob, ZERO_BYTES, true);
        assertEq(uint256(uint128(delta.amount0())), manager.balanceOf(bob, currency0.toId()));
        assertEq(uint256(uint128(delta.amount1())), manager.balanceOf(bob, currency1.toId()));
        assertTrue(delta.amount1() != 0);

        // position manager holds no fees now
        assertApproxEqAbs(manager.balanceOf(address(lpm), currency0.toId()), 0, 1 wei);
        assertApproxEqAbs(manager.balanceOf(address(lpm), currency1.toId()), 0, 1 wei);
    }

    function test_collect_sameRange_erc20(
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidityDeltaAlice,
        uint128 liquidityDeltaBob
    ) public {
        liquidityDeltaAlice = uint128(bound(liquidityDeltaAlice, 100e18, 100_000e18)); // require nontrivial amount of liquidity
        liquidityDeltaBob = uint128(bound(liquidityDeltaBob, 100e18, 100_000e18));
        uint256 tokenIdAlice;
        uint256 tokenIdBob;
        (tokenIdAlice, tokenIdBob, tickLower, tickUpper,,) = createFuzzySameRange(
            lpm,
            alice,
            bob,
            LiquidityRange({key: key, tickLower: tickLower, tickUpper: tickUpper}),
            liquidityDeltaAlice,
            liquidityDeltaBob,
            ZERO_BYTES
        );
        vm.assume(tickLower < -key.tickSpacing && key.tickSpacing < tickUpper); // require two-sided liquidity

        // swap to create fees
        uint256 swapAmount = 0.01e18;
        swap(key, false, int256(swapAmount), ZERO_BYTES);

        // alice collects only her fees
        uint256 balance0AliceBefore = currency0.balanceOf(alice);
        uint256 balance1AliceBefore = currency1.balanceOf(alice);
        vm.prank(alice);
        BalanceDelta delta = lpm.collect(tokenIdAlice, alice, ZERO_BYTES, false);
        uint256 balance0AliceAfter = currency0.balanceOf(alice);
        uint256 balance1AliceAfter = currency1.balanceOf(alice);

        assertEq(balance0AliceBefore, balance0AliceAfter);
        assertEq(uint256(uint128(delta.amount1())), balance1AliceAfter - balance1AliceBefore);
        assertTrue(delta.amount1() != 0);

        // bob collects only his fees
        uint256 balance0BobBefore = currency0.balanceOf(bob);
        uint256 balance1BobBefore = currency1.balanceOf(bob);
        vm.prank(bob);
        delta = lpm.collect(tokenIdBob, bob, ZERO_BYTES, false);
        uint256 balance0BobAfter = currency0.balanceOf(bob);
        uint256 balance1BobAfter = currency1.balanceOf(bob);

        assertEq(balance0BobBefore, balance0BobAfter);
        assertEq(uint256(uint128(delta.amount1())), balance1BobAfter - balance1BobBefore);
        assertTrue(delta.amount1() != 0);

        // position manager holds no fees now
        assertApproxEqAbs(manager.balanceOf(address(lpm), currency0.toId()), 0, 1 wei);
        assertApproxEqAbs(manager.balanceOf(address(lpm), currency1.toId()), 0, 1 wei);
    }

    function test_collect_donate() public {}
    function test_collect_donate_sameRange() public {}

    function test_decreaseLiquidity_sameRange(
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidityDeltaAlice,
        uint128 liquidityDeltaBob
    ) public {
        liquidityDeltaAlice = uint128(bound(liquidityDeltaAlice, 100e18, 100_000e18)); // require nontrivial amount of liquidity
        liquidityDeltaBob = uint128(bound(liquidityDeltaBob, 100e18, 100_000e18));
        uint256 tokenIdAlice;
        uint256 tokenIdBob;
        uint128 liquidityAlice;
        uint128 liquidityBob;
        (tokenIdAlice, tokenIdBob, tickLower, tickUpper, liquidityAlice, liquidityBob) = createFuzzySameRange(
            lpm,
            alice,
            bob,
            LiquidityRange({key: key, tickLower: tickLower, tickUpper: tickUpper}),
            liquidityDeltaAlice,
            liquidityDeltaBob,
            ZERO_BYTES
        );
        vm.assume(tickLower < -key.tickSpacing && key.tickSpacing < tickUpper); // require two-sided liquidity

        // swap to create fees
        uint256 swapAmount = 0.01e18;
        swap(key, true, int256(swapAmount), ZERO_BYTES);

        // alice removes all of her liquidity
        uint256 balance0AliceBefore = manager.balanceOf(alice, currency0.toId());
        uint256 balance1AliceBefore = manager.balanceOf(alice, currency1.toId());
        console2.log(lpm.ownerOf(tokenIdAlice));
        console2.log(alice);
        console2.log(address(this));
        vm.prank(alice);
        BalanceDelta aliceDelta = lpm.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenIdAlice,
                liquidityDelta: liquidityAlice,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1,
                recipient: alice
            }),
            ZERO_BYTES,
            true
        );
        uint256 balance0AliceAfter = manager.balanceOf(alice, currency0.toId());
        uint256 balance1AliceAfter = manager.balanceOf(alice, currency1.toId());

        assertEq(uint256(uint128(aliceDelta.amount0())), balance0AliceAfter - balance0AliceBefore);
        assertEq(uint256(uint128(aliceDelta.amount1())), balance1AliceAfter - balance1AliceBefore);
    }
}
