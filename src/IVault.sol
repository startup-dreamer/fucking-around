// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IVault
 * @dev Interface implementation of the Vault using "Tokenized Vault Standard" as defined in
 * https://eips.ethereum.org/EIPS/eip-4626[EIP-4626].
 *
 */

abstract contract IVault {
        
    /** @dev Error for Zero Address */
    error NullAddressError();

    error ZeroAmountError();

    error TransferError();

    /** @dev Error for zero weight */
    error ZeroWeightError();

    /** @dev Error if sender is not keeper */
    error OnlyKeeperAllowed();

    /** @dev Error if sender is not vault manager */
    error OnlyVaultManager();

    error MarketRemovalFail();

    error TotalAssetIsOutOfThreshold();

    error TotalWeightIsOutOfThreshold();

    event MarketWeightUpdated(address indexed market_, uint256 oldWeight_, uint256 newWeight_);

    event MarketRemovedFromVault(address indexed market_, uint256 weught);

    event RebalancePerformed(uint256 totalAssets_, bool isWithinThreshold_);
}