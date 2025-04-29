// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.5.16;
pragma experimental ABIEncoderV2; // Enables struct return types in external functions

// Import dependencies
import "contracts/lending/compound/PriceOracle.sol"; // Interface for price oracle
import "./compound/tokens/EIP20Interface.sol"; // Standard ERC-20 interface

/**
 * @title ComptrollerLensInterface
 * @dev Interface for Compound's Comptroller with lens functions (view-only queries)
 */
interface ComptrollerLensInterface {
    // Returns market status (listed?) and collateral factor (scaled by 1e18)
    function markets(address) external view returns (bool, uint);

    // Returns the price oracle contract address
    function oracle() external view returns (PriceOracle);

    // Returns account liquidity data: (errorCode, liquidity, shortfall)
    function getAccountLiquidity(address) external view returns (uint, uint, uint);

    // Returns array of CToken addresses the account has entered
    function getAssetsIn(address) external view returns (CToken[] memory);
}

/**
 * @title CErc20
 * @dev Interface for ERC-20-backed Compound cTokens
 */
interface CErc20 {
    // Returns the underlying ERC-20 token address
    function underlying() external view returns (address);
}

/**
 * @title CompoundLens
 * @dev A helper contract to fetch Compound protocol data in batch
 */
contract CompoundLens {
    /**
     * @dev Metadata structure for a CToken
     */
    struct CTokenMetadata {
        address cToken;                     // Address of the cToken contract
        uint exchangeRateCurrent;          // Current exchange rate (scaled by 1e18)
        uint supplyRatePerBlock;           // Current supply APR per block
        uint borrowRatePerBlock;           // Current borrow APR per block
        uint reserveFactorMantissa;        // Reserve factor (scaled by 1e18)
        uint totalBorrows;                 // Total outstanding borrows
        uint totalReserves;                // Total protocol reserves
        uint totalSupply;                 // Total cToken supply
        uint totalCash;                   // Underlying token balance held by cToken
        bool isListed;                     // Is this market listed in Comptroller?
        uint collateralFactorMantissa;     // Collateral factor (scaled by 1e18)
        address underlyingAssetAddress;    // Address of underlying asset (0x0 for ETH)
        uint cTokenDecimals;               // Decimals of the cToken (usually 8)
        uint underlyingDecimals;           // Decimals of the underlying asset
    }

    /**
     * @notice Fetches metadata for a single cToken
     * @param cToken The cToken address to query
     * @return CTokenMetadata struct with market data
     */
    function cTokenMetadata(CToken cToken) public returns (CTokenMetadata memory) {
        // Fetch exchange rate (converts cToken to underlying)
        uint exchangeRateCurrent = cToken.exchangeRateCurrent();
        
        // Get Comptroller instance
        ComptrollerLensInterface comptroller = ComptrollerLensInterface(
            address(cToken.comptroller())
        );
        
        // Check if market is listed and get collateral factor
        (bool isListed, uint collateralFactorMantissa) = comptroller.markets(
            address(cToken)
        );
        
        // Handle ETH vs ERC-20 underlying assets
        address underlyingAssetAddress;
        uint underlyingDecimals;
        if (compareStrings(cToken.symbol(), "fETH")) {
            // ETH market (no underlying token)
            underlyingAssetAddress = address(0);
            underlyingDecimals = 18;
        } else {
            // ERC-20 market - fetch underlying token details
            CErc20 cErc20 = CErc20(address(cToken));
            underlyingAssetAddress = cErc20.underlying();
            underlyingDecimals = EIP20Interface(cErc20.underlying()).decimals();
        }
        
        // Return populated metadata struct
        return CTokenMetadata({
            cToken: address(cToken),
            exchangeRateCurrent: exchangeRateCurrent,
            supplyRatePerBlock: cToken.supplyRatePerBlock(),
            borrowRatePerBlock: cToken.borrowRatePerBlock(),
            reserveFactorMantissa: cToken.reserveFactorMantissa(),
            totalBorrows: cToken.totalBorrows(),
            totalReserves: cToken.totalReserves(),
            totalSupply: cToken.totalSupply(),
            totalCash: cToken.getCash(),
            isListed: isListed,
            collateralFactorMantissa: collateralFactorMantissa,
            underlyingAssetAddress: underlyingAssetAddress,
            cTokenDecimals: cToken.decimals(),
            underlyingDecimals: underlyingDecimals
        });
    }

    /**
     * @notice Batch version of cTokenMetadata for multiple cTokens
     * @param cTokens Array of cToken addresses
     * @return Array of CTokenMetadata structs
     */
    function cTokenMetadataAll(CToken[] calldata cTokens) external returns (CTokenMetadata[] memory) {
        uint cTokenCount = cTokens.length;
        CTokenMetadata[] memory res = new CTokenMetadata[](cTokenCount);
        for (uint i = 0; i < cTokenCount; i++) {
            res[i] = cTokenMetadata(cTokens[i]);
        }
        return res;
    }

    /**
     * @dev Balance information for a user's position in a cToken
     */
    struct CTokenBalances {
        address cToken;                // cToken contract address
        uint balanceOf;                // User's cToken balance
        uint borrowBalanceCurrent;     // User's current borrow balance
        uint balanceOfUnderlying;      // User's underlying token equivalent
        uint tokenBalance;             // User's underlying token balance
        uint tokenAllowance;           // User's allowance to cToken
    }

    /**
     * @notice Fetches balance information for a single cToken
     * @param cToken The cToken address
     * @param account The user address
     * @return CTokenBalances struct with position data
     */
    function cTokenBalances(CToken cToken, address payable account) public returns (CTokenBalances memory) {
        // Get basic cToken balances
        uint balanceOf = cToken.balanceOf(account);
        uint borrowBalanceCurrent = cToken.borrowBalanceCurrent(account);
        uint balanceOfUnderlying = cToken.balanceOfUnderlying(account);
        
        // Handle ETH vs ERC-20 underlying
        uint tokenBalance;
        uint tokenAllowance;
        if (compareStrings(cToken.symbol(), "oETH")) {
            // ETH market - use native balance
            tokenBalance = account.balance;
            tokenAllowance = account.balance; // Infinite allowance equivalent
        } else {
            // ERC-20 market - fetch token balances
            CErc20 cErc20 = CErc20(address(cToken));
            EIP20Interface underlying = EIP20Interface(cErc20.underlying());
            tokenBalance = underlying.balanceOf(account);
            tokenAllowance = underlying.allowance(account, address(cToken));
        }
        
        return CTokenBalances({
            cToken: address(cToken),
            balanceOf: balanceOf,
            borrowBalanceCurrent: borrowBalanceCurrent,
            balanceOfUnderlying: balanceOfUnderlying,
            tokenBalance: tokenBalance,
            tokenAllowance: tokenAllowance
        });
    }

    // [Additional functions follow same pattern with detailed comments...]

    /**
     * @dev Internal helper to compare strings
     */
    function compareStrings(string memory a, string memory b) internal pure returns (bool) {
        return (keccak256(abi.encodePacked((a))) == keccak256(abi.encodePacked((b)));
    }
}
