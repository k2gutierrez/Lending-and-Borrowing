// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import { Pausable } from "../lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
import { Ownable } from "../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import { ECDSA } from "../lib/openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "../lib/openzeppelin-contracts/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title Lending Protocol
 * @author Carlos Gutiérrez
 * @dev A DeFi lending and borrowing protocol that allow users to:
 * - Deposit tokens to earn interest
 * - Borrow tokens against their deposit collateral
 * - Use off-chain signatures for gasless operations
 * - Manage collaterization ratio and liquidations
 */
contract LendingProtocol is ReentrancyGuard, Pausable, Ownable {

    // Custom errors
    error LendingProtocol__InvalidTokenAddress();
    error LendingProtocol__InvalidCollateralFactor();
    error LendingProtocol__MarketAlreadyExists();
    error LendingProtocol__MarketNotActive();
    error LendingProtocol__AmountMustBeGreaterThanZero();
    error LendingProtocol__InsufficientBalance();
    error LendingProtocol__WithdrawalWouldMakeThePositionUnsafe();
    error LendingProtocol__InsufficientLiquidity();
    error LendingProtocol__BorrowWouldExceedCollateralLimit();
    error LendingProtocol__InsufficientBurrow();
    error LendingProtocol__InsufficientBurrowToLiquidate();
    error LendingProtocol__PositionIsNotLiquidatable();
    error LendingProtocol__NoCollateralToSeize();
    error LendingProtocol__InsufficientCollateral();
    error LendingProtocol__SignatureExpired();
    error LendingProtocol__InvalidNonce();
    error LendingProtocol__InvalidSignature();
    error LendingProtocol__InvalidRecipient();

    // Libraries
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // Structs
    struct User {
        uint256 totalDeposited;     // Total amount deposited by user
        uint256 totalBorrowed;      // Total amount borrowed by user
        uint256 lastUpdateTime;     // Last time user's data was updated
        bool isActive;              // Whether user has active positions
    }

    struct Market {
        IERC20 token;               // The token being lent/borrowed
        uint256 totalSupply;        // Total amount supplied to this market
        uint256 totalBorrow;        // Total amount borrowed from this market
        uint256 supplyRate;         // Current supply rate (APY in basis points)
        uint256 borrowRate;         // Current borrow rate (APY in basis points)
        uint256 collateralFactor;   // Collateral factor (0-10000, where 10000 = 100%)
        bool isActive;              // Whether this market is active
    }

    struct SignatureData {
        uint256 nonce;
        uint256 deadline;
        bytes signature;
    }

    // States Variables
    mapping(address user => User userData) private s_users;
    mapping(address user => mapping(address token => uint256 mount)) private s_userDeposits;
    mapping(address user => mapping(address token => uint256 amount)) private s_userBorrows;
    mapping(address token => Market marketData) private s_markets;
    mapping(address => uint256) private s_userNonces;

    address[] private s_supportedTokens;
    uint256 public constant LIQUIDATION_THRESHOLD = 8_000;      // 80% in basis points
    uint256 public constant LIQUIDATION_PENALTY = 500;          // 5% in basis points
    uint256 public constant BASIS_POINT = 10_000;               // 100% in basis points

    // Events
    event MarketAdded(address indexed token, uint256 collateralFactor);
    event MarketUpdated(address indexed token, uint256 collateralFactor);
    event Deposit(address indexed user, address indexed token, uint256 amount);
    event Withdraw(address indexed user, address indexed token, uint256 amount);
    event Borrow(address indexed user, address indexed token, uint256 amount);
    event Repay(address indexed user, address indexed token, uint256 amount);
    event Liquidate(address indexed liquidator, address indexed user, address indexed token, uint256 amount);
    event RatesUpdated(address indexed token, uint256 supplyRate, uint256 borrowRate);

    // Modifiers
    modifier onlyActiveMarket(address token) {
        if (!s_markets[token].isActive) {
            revert LendingProtocol__MarketNotActive();
        }
        _;
    }

    modifier onlyValidSignature(SignatureData calldata sigData) {
        if (block.timestamp > sigData.deadline) revert LendingProtocol__SignatureExpired();
        if (s_userNonces[msg.sender] != sigData.nonce) revert LendingProtocol__InvalidNonce();
        _;
        s_userNonces[msg.sender]++;
    }

    constructor() Ownable(msg.sender) {}

    ////////// Only Owner Functions //////////

    /**
     * @dev Add a new market to the protocol
     * @param token ERC20 token to add
     * @param collateralFactor The collateral factor for this token (0 - 10000)
     * @param inititalSupplyRate Initial supply rate in basis points
     * @param initialBorrowRate Initial borrow rate in basis points
     */
    function addMarket(
        address token, 
        uint256 collateralFactor, 
        uint256 inititalSupplyRate, 
        uint256 initialBorrowRate
    ) external onlyOwner {
        if (token == address(0)) revert LendingProtocol__InvalidTokenAddress();
        if (collateralFactor > BASIS_POINT) revert LendingProtocol__InvalidCollateralFactor();
        if (s_markets[token].isActive) revert LendingProtocol__MarketAlreadyExists();

        s_markets[token] = Market({
            token: IERC20(token),
            totalSupply: 0,
            totalBorrow: 0,
            supplyRate: inititalSupplyRate,
            borrowRate: initialBorrowRate,
            collateralFactor: collateralFactor,
            isActive: true
        });

        s_supportedTokens.push(token);
        emit MarketAdded(token, collateralFactor);
    }

    /**
     * @dev Update market parameters
     * @param token The token address
     * @param collateralFactor New collateral factor
     * @param supplyRate New supply rate
     * @param borrowRate New borrow rate
     */
    function updateMarket(
        address token, uint256 collateralFactor, uint256 supplyRate, uint256 borrowRate
    ) external onlyOwner onlyActiveMarket(token) {
        if (collateralFactor > BASIS_POINT) revert LendingProtocol__InvalidCollateralFactor();

        s_markets[token].collateralFactor = collateralFactor;
        s_markets[token].supplyRate = supplyRate;
        s_markets[token].borrowRate = borrowRate;

        emit MarketUpdated(token, collateralFactor);
        emit RatesUpdated(token, supplyRate, borrowRate);
    }

    ////////// User Functions //////////

    /**
     * @dev Deposit tokens to earn interest
     * @param token The token to deposit
     * @param amount The amount to deposit
     */
    function deposit(address token, uint256 amount) external nonReentrant onlyActiveMarket(token) whenNotPaused {
        if (amount <= 0) revert LendingProtocol__AmountMustBeGreaterThanZero();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        s_userDeposits[msg.sender][token] += amount;
        s_users[msg.sender].totalDeposited += amount;
        s_users[msg.sender].lastUpdateTime = block.timestamp;
        s_users[msg.sender].isActive = true;

        s_markets[token].totalSupply += amount;

        emit Deposit(msg.sender, token, amount);
    }

    function depositWithSignature(
        address token, 
        uint256 amount, 
        SignatureData calldata sigData
    )
        external
        nonReentrant
        whenNotPaused
        onlyActiveMarket(token)
        onlyValidSignature(sigData)
    {
        if (amount <= 0) revert LendingProtocol__AmountMustBeGreaterThanZero();

        // Verify signature
        bytes32 messageHash = keccak256(abi.encodePacked(
            "deposit", 
            token, 
            sigData.nonce,
            sigData.deadline
        ));
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        address signer = ethSignedMessageHash.recover(sigData.signature);
        if (signer != msg.sender) revert LendingProtocol__InvalidSignature();
        if (signer == address(0)) revert LendingProtocol__InvalidSignature();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        s_userDeposits[msg.sender][token] += amount;
        s_users[msg.sender].totalDeposited += amount;
        s_users[msg.sender].lastUpdateTime = block.timestamp;
        s_users[msg.sender].isActive = true;

        s_markets[token].totalSupply += amount;

        emit Deposit(msg.sender, token, amount);
    }

    /**
     * @dev Withdraw deposited tokens
     * @param token The token to withdraw
     * @param amount The amount to withdraw
     */
    function withdraw(address token, uint256 amount) external nonReentrant onlyActiveMarket(token) whenNotPaused {
        if (amount <= 0) revert LendingProtocol__AmountMustBeGreaterThanZero();
        if (s_userDeposits[msg.sender][token] < amount) revert LendingProtocol__InsufficientBalance();
        if (!canWithdraw(msg.sender, token, amount)) revert LendingProtocol__WithdrawalWouldMakeThePositionUnsafe();

        s_userDeposits[msg.sender][token] -= amount;
        s_users[msg.sender].totalDeposited -= amount;
        s_users[msg.sender].lastUpdateTime = block.timestamp;

        if (s_users[msg.sender].totalDeposited == 0) {
            s_users[msg.sender].isActive = false;
        }

        s_markets[token].totalSupply -= amount;

        IERC20(token).safeTransfer(msg.sender, amount);

        emit Withdraw(msg.sender, token, amount);
    }

    function borrow(address token, uint256 amount) external nonReentrant whenNotPaused onlyActiveMarket(token) {
        if (amount <= 0) revert LendingProtocol__AmountMustBeGreaterThanZero();
        if (s_markets[token].totalSupply < amount) revert LendingProtocol__InsufficientLiquidity();
        if (!canBorrow(msg.sender, token, amount)) revert LendingProtocol__BorrowWouldExceedCollateralLimit();

        s_userBorrows[msg.sender][token] += amount;
        s_users[msg.sender].totalBorrowed += amount;
        s_users[msg.sender].lastUpdateTime = block.timestamp;
        s_users[msg.sender].isActive = true;

        s_markets[token].totalBorrow += amount;

        IERC20(token).safeTransfer(msg.sender, amount);

        emit Borrow(msg.sender, token, amount);
    }
    
    function repay(address token, uint256 amount) external nonReentrant whenNotPaused onlyActiveMarket(token) {
        if (amount <= 0) revert LendingProtocol__AmountMustBeGreaterThanZero();
        if (s_userBorrows[msg.sender][token] < amount) revert LendingProtocol__InsufficientBurrow();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        s_userBorrows[msg.sender][token] -= amount;
        s_users[msg.sender].totalBorrowed -= amount;
        s_users[msg.sender].lastUpdateTime = block.timestamp;

        if (s_users[msg.sender].totalBorrowed == 0) {
            s_users[msg.sender].isActive = false;
        }

        s_markets[token].totalBorrow -= amount; 

        emit Repay(msg.sender, token, amount);
    }

    /**
     * @dev Check of a user can withdraw without making position unsafe
     * @param user The user address
     * @param token The token to withdraw
     * @param amount The amount to withdraw
     * @return True if withdrawal is safe
     */
    function canWithdraw(address user, address token, uint256 amount) public view returns(bool) {
        uint256 currentRatio = getCollateralizationRatio(user);
        if (currentRatio == type(uint256).max) return true;

        // Calculate new ratio after withdraw
        uint256 newCollateralValue = 0;
        uint256 totalBorrowValue = 0;
        for (uint256 i = 0; i < s_supportedTokens.length; i++) {
            address supportedToken = s_supportedTokens[i];
            if (s_markets[supportedToken].isActive) {
                uint256 depositAmount = s_userDeposits[user][supportedToken];
                uint256 borrowAmount = s_userBorrows[user][supportedToken];

                if (supportedToken == token) {
                    depositAmount = depositAmount > amount ? depositAmount - amount : 0;
                }

                if (depositAmount > 0) {
                    newCollateralValue += (depositAmount * s_markets[supportedToken].collateralFactor) / BASIS_POINT;
                }

                if (borrowAmount > 0) {
                    totalBorrowValue += borrowAmount;
                }
            }
        }

        if (totalBorrowValue == 0) return true;
        uint256 newRatio = (newCollateralValue * BASIS_POINT) / totalBorrowValue;
        return newRatio >= LIQUIDATION_THRESHOLD;
    }

    /**
     * @dev Check if a user can borrow additional tokens
     * @param user The user address
     * @param token The token to borrow
     * @param amount The amount to borrow
     */
    function canBorrow(address user, address token, uint256 amount) public view returns(bool) {
        // uint256 currentRatio = getCollateralizationRatio(user);
        // if (currentRatio == type(uint256).max) return true;  This causes that the first borrow would be umlimited in amount

        // Calculate new ratio after borrow
        uint256 totalCollateralValue = 0;
        uint256 totalBorrowValue = 0;

        for (uint256 i = 0; i < s_supportedTokens.length; i++) {
            address supportedToken = s_supportedTokens[i];
            if (s_markets[supportedToken].isActive) {
                uint256 depositAmount = s_userDeposits[user][supportedToken];
                uint256 borrowAmount = s_userBorrows[user][supportedToken];

                if (supportedToken == token) {
                    borrowAmount += amount;
                }

                if (depositAmount > 0) {
                    totalCollateralValue += (depositAmount * s_markets[supportedToken].collateralFactor) / BASIS_POINT;
                }

                if (borrowAmount > 0) {
                    totalBorrowValue += borrowAmount;
                }
            }
        }

        if (totalBorrowValue == 0) return true;
        uint256 newRatio = (totalCollateralValue * BASIS_POINT) / totalBorrowValue;
        return newRatio >= LIQUIDATION_THRESHOLD;
    }

    /**
     * @dev Get user's current collaterization ratio
     * @param user The user address
     * @return ratio The collaterization ratio in basis points
     */
    function getCollateralizationRatio(address user) public view returns(uint256 ratio) {
        uint256 totalCollateralValue = 0;
        uint256 totalBorrowValue = 0;

        for (uint256 i = 0; i < s_supportedTokens.length; i++) {
            address token = s_supportedTokens[i];
            if (s_markets[token].isActive) {
                uint256 depositAmount = s_userDeposits[user][token];
                uint256 borrowAmount = s_userBorrows[user][token];

                if (depositAmount > 0) {
                    totalCollateralValue += (depositAmount * s_markets[token].collateralFactor) / BASIS_POINT;
                }

                if (borrowAmount > 0) {
                    totalBorrowValue += borrowAmount;
                }
            }
        }

        if (totalBorrowValue == 0) return type(uint256).max;
        return (totalCollateralValue * BASIS_POINT) / totalBorrowValue;
    }

    /**
     * @dev Liquidate an undercollateralized position
     * @param user The user to liquidate
     * @param token The token to liquidate
     * @param amount The amount to liquidate
     */
    function liquidate(address user, address token, uint256 amount) 
        external
        nonReentrant
        whenNotPaused
        onlyActiveMarket(token)
    {
        if (amount <= 0) revert LendingProtocol__AmountMustBeGreaterThanZero();
        if (s_userBorrows[user][token] < amount) revert LendingProtocol__InsufficientBurrowToLiquidate();
        if (!isLiquidatable(user)) revert LendingProtocol__PositionIsNotLiquidatable();

        uint256 collateralToSeize = (amount * (BASIS_POINT + LIQUIDATION_PENALTY)) / BASIS_POINT;

        // Find collateral token to seize
        address collateralToken = _findBestCollateral(user);
        if (collateralToken == address(0)) revert LendingProtocol__NoCollateralToSeize();
        if (s_userDeposits[user][collateralToken] < collateralToSeize) revert LendingProtocol__InsufficientCollateral();

        // Transfer Borrowed tokens from liquidator
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Update user's borrow
        s_userBorrows[user][token] -= amount;
        s_users[user].totalBorrowed -= amount;
        s_markets[token].totalBorrow -= amount;

        // Seize collateral
        s_userDeposits[user][collateralToken] -= collateralToSeize;
        s_users[user].totalDeposited -= collateralToSeize;
        s_markets[collateralToken].totalSupply -= collateralToSeize;

        // Transfer collateral to liquidator
        IERC20(collateralToken).safeTransfer(msg.sender, collateralToSeize);

        emit Liquidate(msg.sender, user, token, amount);
    }

    /**
     * @dev Check if a user's position is liquiditable
     * @param user The user address
     * @return True if position ca be liquidated
     */
    function isLiquidatable(address user) public view returns(bool) {
        uint256 ratio = getCollateralizationRatio(user);
        return ratio < LIQUIDATION_THRESHOLD;
    }

    /**
     * @dev Find the best collateral token for liquidation
     * @param user The user address
     * @return The address of the best collateral token
     */
    function _findBestCollateral(address user) internal view returns(address) {
        address bestToken = address(0);
        uint256 bestValue = 0;

        for (uint256 i; i < s_supportedTokens.length; i++) {
            address token = s_supportedTokens[i];
            if (s_markets[token].isActive && s_userDeposits[user][token] > 0) {
                uint256 value = (s_userDeposits[user][token] * s_markets[token].collateralFactor) / BASIS_POINT;
                if (value > bestValue) {
                    bestValue = value;
                    bestToken = token;
                }
            }
        }

        return bestToken;
    }

    ////////// Utility Only Owner Functions //////////

    /**
     * @dev Pause the protocol
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @dev Unpause the protocol
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Emergency function to recover stuck tokens
     * @param token The token to recover
     * @param to The address to send tokens to
     * @param amount The amount to recover
     */
    function emergencyRecover(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert LendingProtocol__InvalidRecipient();
        IERC20(token).safeTransfer(to, amount);
    }

    ////////// Getter Functions //////////

    /**
     * @dev Get the user's nonce for signature verifications
     * @param user The user address
     * @return The current nonce
     */
    function getNonce(address user) external view returns(uint256) {
        return s_userNonces[user];
    }

    /**
     * @dev Get the market information
     * @param token The token address
     * @return Market information
     */
    function getMarket(address token) external view returns(Market memory) {
        return s_markets[token];
    }

    /**
     * @dev Get user information
     * @param user The user address
     * @return User information
     */
    function getUser(address user) external view returns(User memory) {
        return s_users[user];
    }

    /**
     * @dev Get the user's deposits for a specific token
     * @param user The user address
     * @param token The token address
     * @return The deposit amount
     */
    function getUserDeposit(address user, address token) external view returns(uint256) {
        return s_userDeposits[user][token];
    }

    /**
     * @dev Get the user's borrows for a specific token
     * @param user The user address
     * @param token The token address
     * @return The borrow amount
     */
    function getUserBorrow(address user, address token) external view returns(uint256) {
        return s_userBorrows[user][token];
    }

    /**
     * @dev Get all supported tokens
     * @return Array of supported tokens addresses
     */
    function getSupportedTokens() external view returns(address[] memory) {
        return s_supportedTokens;
    }

    /**
     * @dev Get the Liquidation Threshold
     * @return The liquidation threshold number
     */
    function getLiquidationThreshold() external pure returns(uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    /**
     * @dev Get the Liquidation Penalty
     * @return The liquidation Penalty number
     */
    function getLiquidationPenalty() external pure returns(uint256) {
        return LIQUIDATION_PENALTY;
    }

    /**
     * @dev Get the Basis Points
     * @return The basis points number
     */
    function getBasisPoints() external pure returns(uint256) {
        return BASIS_POINT;
    }

}