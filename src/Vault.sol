// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title Vault
 * @dev Implementation of the Vault using "Tokenized Vault Standard" as defined in
 * https://eips.ethereum.org/EIPS/eip-4626[EIP-4626].
 *
 */

import {ERC4626} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {EnumerableMap} from "openzeppelin-contracts/contracts/utils/structs/EnumerableMap.sol";
import {Reader} from "gmx-synthetics/contracts/reader/Reader.sol";
import {DataStore} from "gmx-synthetics/contracts/data/DataStore.sol";
import {Market} from "gmx-synthetics/contracts/market/Market.sol";
import {Price} from "gmx-synthetics/contracts/price/Price.sol";
import {IVault} from "./IVault.sol";

abstract contract Vault is IVault, ERC4626 {
    using Math for uint256;
    using Market for Market.Props;
    using Price for Price.Props;
    using EnumerableMap for EnumerableMap.AddressToUintMap;

    // GMX-V2 contracts
    DataStore private datastore;
    Reader private reader;
    IERC20 private immutable _asset;
    address public immutable keeper;
    address public immutable vaultManager;
    uint16 public constant MAX_BPS = 10000;

    uint256 internal assetThreshold; // in bps
    uint256 internal weightThreshold; // in bps
    uint256 internal depositCap;
    uint256 public totalWeight; // in bps

    // Address to Uint map to have the key value data pair of market address and corresponding weights
    EnumerableMap.AddressToUintMap internal targetMarketWeight;

    modifier onlyKeeper() {
        if (msg.sender != keeper) {
            revert OnlyKeeperAllowed();
        }
        _;
    }

    modifier onlyVaultManager() {
        if (msg.sender != vaultManager) {
            revert OnlyVaultManager();
        }
        _;
    }

    /**
     * @dev Set the underlying asset contract. This must be an ERC20-compatible contract (ERC20 or ERC777).
     */
    constructor(
        IERC20 asset_,
        address dataStore_,
        address keeper_,
        address vaultManager_,
        uint256 assetThreshold_,
        uint256 depositCap_
    ) ERC4626(asset_) {
        asset_ = _asset;
        datastore = DataStore(dataStore_);
        keeper = keeper_;
        vaultManager = vaultManager_;
        assetThreshold = assetThreshold_;
        depositCap = depositCap_;
    }

    function setMarketWithWeights(address market_, uint256 weight_) external onlyVaultManager {
        if (market_ == address(0)) {
            revert NullAddressError();
        }
        if (weight_ == uint256(0)) {
            revert ZeroWeightError();
        }
        (bool marketExists, uint256 oldWeight) = targetMarketWeight.tryGet(market_);

        // Check if the market already exists
        if (!marketExists) {
            // Add the new market and its weight
            targetMarketWeight.set(market_, weight_);
        } else {
            // Update the target weight
            targetMarketWeight.set(market_, weight_);
            totalWeight = totalWeight + weight_ - oldWeight;
        }

        emit MarketWeightUpdated(market_, oldWeight, weight_);
    }

    function removeMarketFromVault(address market_) external onlyVaultManager {
        uint256 weight = targetMarketWeight.get(market_);
        bool success = targetMarketWeight.remove(market_);

        if (!success) {
            revert MarketRemovalFail();
        }
        emit MarketRemovedFromVault(market_, weight);
    }

    function rebalance(int256[] calldata amounts_) external onlyKeeper {
        uint256 length = targetMarketWeight.length();

        require(amounts_.length == length, "Invalid amounts length");

        uint256 prevTotalAsset = totalAssets();
        // uint256 prevWeight;

        for (uint256 i = 0; i < length;) {
            int256 amount = amounts_[i];
            uint256 positiveAmount = _toFloorUint(amount);
            (address market, uint256 prevWeight) = targetMarketWeight.at(i);
            if (amount > 0) {
                _transferIn(market, positiveAmount);
            } else if (amount < 0) {
                _transferOut(market, positiveAmount);
            }
            uint256 currentWeight = currentWeight(market, false);

            targetMarketWeight.set(market, currentWeight);
            unchecked {
                ++i;
            }
            //! doubt shouldn't this be checked for each market...???
            /**
             * Check if the currentweight is within a certain threshold
             * @example prevWeight = 8000, weightThreshold = 1000 (10%), MAX_BPS = 10000
             * so the expression is equivalent to (8000 * (10000 + 1000) / 10000 ) => (8000 * 1.1)
             * And (8000 * (10000 - 1000) / 10000 ) => (8000 * 0.9)
             * so currentweight should be (8000 * 0.9) < CW < (8000 * 1.1)
             */
            if (
                currentWeight < (prevWeight * (MAX_BPS + weightThreshold) / MAX_BPS)
                    && currentWeight > (prevWeight * (MAX_BPS - weightThreshold) / MAX_BPS)
            ) {
                revert TotalWeightIsOutOfThreshold();
            }
        }

        /**
         * Check if the totalAssets() is within a certain threshold
         * @example prevTotalAsset = 80, assetThreshold = 1000 (10%), MAX_BPS = 10000
         * so the expression is equivalent to (80 * (10000 + 1000) / 10000 ) => (80 * 1.1)
         * And (80 * (10000 - 1000) / 10000 ) => (80 * 0.9)
         * So TotalAsset should always be (80 * 0.9) < TA < (80 * 1.1)
         */
        if (
            totalAssets() < (prevTotalAsset * (MAX_BPS + assetThreshold) / MAX_BPS)
                && totalAssets() > (prevTotalAsset * (MAX_BPS - assetThreshold) / MAX_BPS)
        ) {
            revert TotalAssetIsOutOfThreshold();
        }
    }

    /**
     * @dev returns the current weight in bps basis market value of token denominated
     * in USD and total asset value of all markets denominated in USD
     */
    function currentWeight(address market_, bool maximize_) public view returns (uint256) {
        uint256 marketTokenValue = _stakedMarketTokenValue(market_, maximize_);
        return ((_getAssetTokenValueDenominatedAssetPrice(market_, marketTokenValue) / totalAssets()) * MAX_BPS);
    }

    /**
     * @dev Calculates the total assets value in the vault of all the markets in a pool
     * denominated in underlying asset value of the vault
     */
    function totalAssets() public view override returns (uint256) {
        uint256 marketMapLength = targetMarketWeight.length();
        uint256 totalTokenValue;
        bool maximize = false;

        for (uint256 i = 0; i < marketMapLength;) {
            (address marketAddress, uint256 weight) = targetMarketWeight.at(i);
            uint256 marketTokenValue = _stakedMarketTokenValue(marketAddress, maximize);

            totalTokenValue += marketTokenValue;

            unchecked {
                ++i;
            }
        }
        // // Get the price of the asset token from the price feed contract
        // uint256 assetPrice = _toFloorUint(_getAssetPrice(address(_asset)));

        //! Todo Handle decimal multiplier value
        // // Calculate the amount of asset tokens staked in the market both denominated in USD
        // uint256 assetTokensStaked = (totalTokenValue / assetPrice);

        return
            _asset.balanceOf(address(this)) + _getAssetTokenValueDenominatedAssetPrice(address(_asset), totalTokenValue);
    }

    /**
     * @dev returns asset token value
     */
    function _getAssetTokenValueDenominatedAssetPrice(address asset_, uint256 tokenValue_)
        internal
        view
        returns (uint256)
    {
        // will fetch the asset price from oracle services
        // return price;
    }

    /**
     * @dev See {IERC4626-maxDeposit}.
     */
    function maxDeposit(address) public view override returns (uint256) {
        return depositCap - totalAssets();
    }

    /**
     * @dev See {IERC4626-maxMint}.
     */
    function maxMint(address) public view override returns (uint256) {
        return super.convertToShares(maxDeposit(address(0)));
    }

    /**
     * @dev Internal conversion function (from assets to shares) with support for rounding direction.
     * @notice Just a small gas optimization else it is same as _convertToShares of super may be depracated
     * considering this is just a proof of concept contract
     */
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        uint256 supply = totalSupply(); // Saves an extra SLOAD if totalSupply is non-zero.

        return
            supply == 0 ? assets : assets.mulDiv(totalSupply() + 10 ** _decimalsOffset(), totalAssets() + 1, rounding);
    }

    /**
     * @dev This function will fetch price from the gmx or oracle of the current market provided
     * @custom:decimal this will return the value with a decimal multiplier of 10^30
     */
    function _marketTokenPrice(address market_)
        internal
        view
        returns (
            Price.Props memory indexTokenPrice,
            Price.Props memory longTokenPrice,
            Price.Props memory shortTokenPrice,
            bytes32 pnlFactorType
        )
    {
        // will return the token price associiated to each token
    }

    /**
     * @notice Calculate the value of asset tokens staked in a market
     * @return The amount of asset tokens staked in the market
     * @custom:decimal this will return the value with a decimal multiplier of the asset decimal value
     */
    function _stakedMarketTokenValue(address market_, bool maximize_) internal view returns (uint256) {
        // will get the market props from datastore and market address
        Market.Props memory market = reader.getMarket(datastore, market_);
        // fetches the price of index, long, short and plnFactorType of market type from market address
        (
            Price.Props memory indexTokenPrice,
            Price.Props memory longTokenPrice,
            Price.Props memory shortTokenPrice,
            bytes32 pnlFactorType
        ) = _marketTokenPrice(market_);

        // Get the market token price and pool value price
        (int256 marketTokenPrice,) = reader.getMarketTokenPrice(
            datastore, market, indexTokenPrice, longTokenPrice, shortTokenPrice, pnlFactorType, maximize_
        );

        uint256 positiveMarketTokenPrice = _toFloorUint(marketTokenPrice);
        uint256 positiveMarketTokenPriceAssetDecimalDenominated = convertToAssetDecimalDenominated(positiveMarketTokenPrice, 30, market_);

        return positiveMarketTokenPriceAssetDecimalDenominated * IERC20(market_).balanceOf(address(this));
    }

    /**
     * Example:
     * positiveMarketTokenPrice = 46453 * 10**30;
     * market token decimal = 8, asset token decimal = 18;
     * To convert the value directly to asset decimal value 
     * uint 256 convertedValue = 46453 * 10**30 / 10**8 * (assets decimal value) / 10**30;
     */
    function convertToAssetDecimalDenominated(uint256 inputValue, uint256 powerOf10, address market_) public pure returns (uint256) {
        require(inputValue > 0, "Input value must be greater than zero");

        uint256 oracleDenominator = 10**powerOf10;
        uint256 marketDecimal = IERC20Metadata(market_).decimals();
        uint256 assetDecimal = IERC20Metadata(address(_asset)).decimals();

        uint256 inputValueDenominatedAssetDecimal = ((inputValue / marketDecimal) * assetDecimal) / oracleDenominator;

        return inputValueDenominatedAssetDecimal;
    }

    function _toFloorUint(int256 value_) internal pure returns (uint256) {
        return value_ > 0 ? uint256(value_) : 0;
    }

    function _transferIn(address market_, uint256 amount_) internal {
        if (amount_ == 0) revert ZeroAmountError();
        if (market_ == address(0)) revert NullAddressError();

        IERC20 token = IERC20(market_);
        bool success = token.transferFrom(msg.sender, address(this), amount_);

        if (!success) revert TransferError();
    }

    function _transferOut(address market_, uint256 amount_) internal {
        if (amount_ == 0) revert ZeroAmountError();
        if (market_ == address(0)) revert NullAddressError();

        IERC20 token = IERC20(market_);
        bool success = token.transfer(market_, amount_);

        if (!success) revert TransferError();
    }
}

// what is pnlfactorType and maximize here (pending)

// to handel decimal market token Price = 10^30 * balanceOf(token) / token decimals (pending)
// make comparison out side the loop (resolved)
// I am changing all of the token value to be denominated in asset to get current weight also.
// logic tranferIn and transferOut
