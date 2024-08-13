// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {MiddlewareProtect} from "./MiddlewareProtect.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IViewQuoter} from "../interfaces/IViewQuoter.sol";

contract MiddlewareProtectFactory {
    event MiddlewareCreated(address implementation, address middleware);

    mapping(address => address) private _implementations;

    IPoolManager public immutable poolManager;
    IViewQuoter public immutable viewQuoter;

    constructor(IPoolManager _poolManager, IViewQuoter _viewQuoter) {
        poolManager = _poolManager;
        viewQuoter = _viewQuoter;
    }

    /**
     * @notice Get the implementation address for a given middleware.
     * @param middleware The address of the middleware.
     * @return implementation The address of the implementation.
     */
    function getImplementation(address middleware) external view returns (address implementation) {
        return _implementations[middleware];
    }

    /**
     * @notice Create a new middlewareRemove contract.
     * @param implementation The address of the implementation or an existing hook.
     * @param salt The salt for deploying to the right flags.
     * @return middleware The address of the newly created middlewareRemove contract.
     */
    function createMiddleware(address implementation, bytes32 salt) external returns (address middleware) {
        middleware = address(new MiddlewareProtect{salt: salt}(poolManager, viewQuoter, implementation));
        _implementations[middleware] = implementation;
        emit MiddlewareCreated(implementation, middleware);
    }
}
