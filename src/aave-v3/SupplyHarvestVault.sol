// SPDX-License-Identifier: GNU AGPLv3
pragma solidity 0.8.10;

import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {ISupplyHarvestVault} from "./interfaces/ISupplyHarvestVault.sol";
import {ISwapper} from "../interfaces/ISwapper.sol";

import {SafeTransferLib, ERC20} from "@rari-capital/solmate/src/utils/SafeTransferLib.sol";
import {PercentageMath} from "@morpho-labs/morpho-utils/math/PercentageMath.sol";
import {WadRayMath} from "@morpho-labs/morpho-utils/math/WadRayMath.sol";

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {SupplyVaultBase} from "./SupplyVaultBase.sol";

/// @title SupplyHarvestVault.
/// @author Morpho Labs.
/// @custom:contact security@morpho.xyz
/// @notice ERC4626-upgradeable Tokenized Vault implementation for Morpho-Aave, which can harvest accrued COMP rewards, swap them and re-supply them through Morpho-Rewardsound.
contract SupplyHarvestVault is ISupplyHarvestVault, SupplyVaultBase, OwnableUpgradeable {
    using SafeTransferLib for ERC20;
    using PercentageMath for uint256;
    using WadRayMath for uint256;

    /// EVENTS ///

    /// @notice Emitted when an harvest is done.
    /// @param harvester The address of the harvester receiving the fee.
    /// @param rewardToken The address of the reward token swapped.
    /// @param rewardsAmount The amount of rewards in underlying asset which is supplied to Morpho.
    /// @param rewardsFee The amount of underlying asset sent to the harvester.
    event Harvested(
        address indexed harvester,
        address indexed rewardToken,
        uint256 rewardsAmount,
        uint256 rewardsFee
    );

    /// @notice Emitted when the fee for harvesting is set.
    /// @param newHarvestingFee The new harvesting fee.
    event HarvestingFeeSet(uint16 newHarvestingFee);

    /// @notice Emitted when the swapper is set.
    /// @param newSwapper The new swapper contract.
    event SwapperSet(address newSwapper);

    /// ERRORS ///

    /// @notice Thrown when the input is above the maximum basis points value (100%).
    /// @param _value The value exceeding the threshold.
    error ExceedsMaxBasisPoints(uint16 _value);

    /// STORAGE ///

    uint16 public constant MAX_BASIS_POINTS = 100_00; // 100% in basis points.

    uint16 public harvestingFee; // The fee taken by the claimer when harvesting the vault (in bps).
    ISwapper public swapper; // Swapper contract to swap reward tokens for underlying asset.

    /// INITIALIZER ///

    /// @notice Initializes the vault.
    /// @param _morpho The address of the main Morpho contract.
    /// @param _poolToken The address of the pool token corresponding to the market to supply through this vault.
    /// @param _name The name of the ERC20 token associated to this tokenized vault.
    /// @param _symbol The symbol of the ERC20 token associated to this tokenized vault.
    /// @param _initialDeposit The amount of the initial deposit used to prevent pricePerShare manipulation.
    /// @param _harvestingFee The fee taken by the claimer when harvesting the vault (in bps).
    function initialize(
        address _morpho,
        address _poolToken,
        string calldata _name,
        string calldata _symbol,
        uint256 _initialDeposit,
        uint16 _harvestingFee,
        address _swapper
    ) external initializer {
        if (_swapper == address(0)) revert ZeroAddress();
        if (_harvestingFee > MAX_BASIS_POINTS) revert ExceedsMaxBasisPoints(_harvestingFee);

        __Ownable_init();
        __SupplyVaultBase_init(_morpho, _poolToken, _name, _symbol, _initialDeposit);

        harvestingFee = _harvestingFee;
        swapper = ISwapper(_swapper);
    }

    /// GOVERNANCE ///

    /// @notice Sets the fee taken by the claimer from the total amount of COMP rewards when harvesting the vault.
    /// @param _newHarvestingFee The new harvesting fee to set (in bps).
    function setHarvestingFee(uint16 _newHarvestingFee) external onlyOwner {
        if (_newHarvestingFee > MAX_BASIS_POINTS) revert ExceedsMaxBasisPoints(_newHarvestingFee);

        harvestingFee = _newHarvestingFee;
        emit HarvestingFeeSet(_newHarvestingFee);
    }

    /// @notice Sets the swapper contract to swap reward tokens for underlying asset.
    /// @param _swapper The new swapper to set.testShouldNotSetHarvestingFeeTooLarge
    function setSwapper(address _swapper) external onlyOwner {
        swapper = ISwapper(_swapper);
        emit SwapperSet(_swapper);
    }

    /// EXTERNAL ///

    /// @notice Harvests the vault: claims rewards from the underlying pool, swaps them for the underlying asset and supply them through Morpho.
    /// @return rewardTokens The addresses of reward tokens claimed.
    /// @return rewardsAmounts The amount of rewards claimed for each reward token (in underlying).
    /// @return totalSupplied The total amount of rewards swapped and supplied to Morpho (in underlying).
    /// @return totalRewardsFee The total amount of fees swapped and taken by the claimer (in underlying).
    function harvest()
        external
        returns (
            address[] memory rewardTokens,
            uint256[] memory rewardsAmounts,
            uint256 totalSupplied,
            uint256 totalRewardsFee
        )
    {
        address poolTokenMem = poolToken;

        {
            address[] memory poolTokens = new address[](1);
            poolTokens[0] = poolTokenMem;
            (rewardTokens, rewardsAmounts) = morpho.claimRewards(poolTokens, false);
        }

        address assetMem = asset();
        ISwapper swapperMem = swapper;
        uint16 harvestingFeeMem = harvestingFee;
        uint256 nbRewardTokens = rewardTokens.length;

        for (uint256 i; i < nbRewardTokens; ) {
            uint256 rewardsAmount = rewardsAmounts[i];

            if (rewardsAmount > 0) {
                ERC20 rewardToken = ERC20(rewardTokens[i]);

                // Note: Uniswap pairs are considered to have enough market depth.
                // The amount swapped is considered low enough to avoid relying on any oracle.
                if (assetMem != address(rewardToken)) {
                    rewardToken.safeTransfer(address(swapperMem), rewardsAmount);
                    rewardsAmount = swapperMem.executeSwap(
                        address(rewardToken),
                        rewardsAmount,
                        assetMem,
                        address(this)
                    );
                }

                uint256 rewardFee;
                if (harvestingFeeMem > 0) {
                    rewardFee = rewardsAmount.percentMul(harvestingFeeMem);
                    unchecked {
                        totalRewardsFee += rewardFee;
                        rewardsAmount -= rewardFee;
                    }
                }

                rewardsAmounts[i] = rewardsAmount;
                totalSupplied += rewardsAmount;

                emit Harvested(msg.sender, address(rewardToken), rewardsAmount, rewardFee);
            }

            unchecked {
                ++i;
            }
        }

        ERC20(assetMem).safeTransfer(msg.sender, totalRewardsFee);
        morpho.supply(poolTokenMem, address(this), totalSupplied);
    }
}
