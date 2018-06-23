pragma solidity 0.4.20;

import 'reporting/IMarket.sol';
import 'trading/IShareToken.sol';
import 'trading/ICash.sol';
import 'libraries/token/ERC20.sol';
import 'libraries/math/SafeMathUint256.sol';
import 'libraries/ReentrancyGuard.sol';
import 'trading/ICompleteSets.sol';
import 'Augur.sol';
import 'IController.sol';

contract ZeroXPoC is ReentrancyGuard {
    using SafeMathUint256 for uint256;

    // Error Codes
    enum Errors {
        ORDER_EXPIRED,                    // Order has already expired
        ORDER_FULLY_FILLED_OR_CANCELLED,  // Order has already been fully filled or cancelled
        ROUNDING_ERROR_TOO_LARGE,         // Rounding error too large
        INSUFFICIENT_BALANCE_OR_ALLOWANCE // Insufficient balance or allowance for token transfer
    }

    uint16 constant public EXTERNAL_QUERY_GAS_LIMIT = 4999;    // Changes to state require at least 5000 gas

    // token => account => balance
    mapping(address => mapping(address => uint256)) public tokenBalances;

    // orderHash => amounts of Amount filled or cancelled.
    mapping (bytes32 => uint) public filled;
    mapping (bytes32 => uint) public cancelled;

    Augur public augur;
    ICompleteSets public completeSets;
    IController public controller;

    event Fill(
        address taker,
        uint256 amountFilled,
        bytes32 orderHash
    );

    event Cancel(
        bytes32 orderHash,
        uint256 cancelledAmount
    );

    event Error(
        uint8 indexed errorId,
        bytes32 indexed orderHash
    );

    struct Order {
        address maker;
        address market;
        uint256 outcome;
        uint256 orderType;
        uint256 amount;
        uint256 price;
        uint expirationTimestampInSec;
        bytes32 orderHash;
    }

    event Deposit(
        address indexed account,
        address indexed shareToken,
        uint256 amountDeposited,
        uint256 amountHeld
    );

    event Withdraw(
        address indexed account,
        address indexed shareToken,
        uint256 amountWithdrawn,
        uint256 amountHeld
    );

    function ZeroXPoC(Augur _augur) public {
        augur = _augur;
        controller = _augur.getController();
        completeSets = ICompleteSets(controller.lookup("CompleteSets"));
    }

    /*
    / Market Share management
    */

    function deposit(ERC20 _token, uint256 _amount) public nonReentrant returns (bool) {
        require(_token != ERC20(0));
        require(_token.transferFrom(msg.sender, this, _amount));
        tokenBalances[_token][msg.sender] = tokenBalances[_token][msg.sender].add(_amount);
        Deposit(msg.sender, _token, _amount, tokenBalances[_token][msg.sender]);
        return true;
    }

    function withdraw(ERC20 _token, uint256 _amount) public nonReentrant returns (bool) {
        require(_token != ERC20(0));
        uint256 _heldAmount = tokenBalances[_token][msg.sender];
        require(_heldAmount >= _amount);
        require(_token.transfer(msg.sender, _amount));
        tokenBalances[_token][msg.sender] = _heldAmount.sub(_amount);
        Withdraw(msg.sender, _token, _amount, tokenBalances[_token][msg.sender]);
        return true;
    }

    /*
    / Exchange functions
    */

    /// @dev Fills the input order.
    /// @param orderAddresses Array of order's maker, market
    /// @param orderValues Array of order's outcome, orderType, amount, price, expirationTimestampInSec, and salt.
    /// @param fillAmount Desired amount to fill.
    /// @param v ECDSA signature parameter v.
    /// @param r ECDSA signature parameters r.
    /// @param s ECDSA signature parameters s.
    /// @return success.
    function fillOrder(
          address[2] orderAddresses,
          uint[6] orderValues,
          uint fillAmount,
          uint8 v,
          bytes32 r,
          bytes32 s)
          public
          nonReentrant
          returns (bool)
    {
        Order memory order = Order({
            maker: orderAddresses[0],
            market: orderAddresses[1],
            outcome: orderValues[0],
            orderType: orderValues[1],
            amount: orderValues[2],
            price: orderValues[3],
            expirationTimestampInSec: orderValues[4],
            orderHash: getOrderHash(orderAddresses, orderValues)
        });

        require(order.amount > 0 && fillAmount > 0);
        require(isValidSignature(
            order.maker,
            order.orderHash,
            v,
            r,
            s
        ));

        if (controller.getTimestamp() >= order.expirationTimestampInSec) {
            Error(uint8(Errors.ORDER_EXPIRED), order.orderHash);
            return false;
        }

        uint remainingAmount = order.amount.sub(getUnavailableAmount(order.orderHash));
        uint toFillAmount = fillAmount.min(remainingAmount);
        if (toFillAmount == 0) {
            Error(uint8(Errors.ORDER_FULLY_FILLED_OR_CANCELLED), order.orderHash);
            return false;
        }

        filled[order.orderHash] = filled[order.orderHash].add(toFillAmount);

        Fill(
            msg.sender,
            toFillAmount,
            order.orderHash
        );

        // longShareToken =
        // shortShareTokens = []

        // shortParticipant =
        // longParticipant =

        // longSharesHeldByShortParticipant = getBalance(shortParticipant, longShareToken)
        // shortSharesHeldByLongParticipant = 0;
        // for i < shortShareTokens
        //     shortSharesHeldByLongParticipant += getBalance(longParticipant, shortShareTokens[i])

        // numCompleteSets = min(longSharesHeldByShortParticipant, shortSharesHeldByLongParticipant, toFillAmount)
        // if (numCompleteSets > 0)
        //     sell complete sets
        //     update longSharesHeldByShortParticipant (decrease)
        //     update shortSharesHeldByLongParticipant (decrease)
        //     update toFillAmount (decrease)
        //     update share token balances (decrease)
        //     update Cash balances (increase)
        //
        // if (toFillAmount > 0 && longSharesHeldByShortParticipant > 0)
        //     sub from short participants long share balance
        //     add to long participants long share balance
        //     add to short participants cash balance
        //     sub from long participants cash balance
        //     update toFillAmount (decrease)
        //
        // if (toFillAmount > 0 && shortSharesHeldByLongParticipant > 0)
        //     sub from long participants short share balances
        //     add to short participants short share balances
        //     add to long participants cash balance
        //     sub from short participants cash balance
        //     update toFillAmount (decrease)
        //
        // if (toFillAmount > 0)
        //     buy complete sets
        //     update share token balances (increase)
        //     update Cash balances (decrease)

        return true;
    }

    /// @dev Cancels the input order.
    /// @param orderAddresses Array of order's maker and market.
    /// @param orderValues Array of order's outcome, orderType, amount, price, expirationTimestampInSec, and salt.
    /// @param cancelAmount Desired amount to cancel in order.
    /// @return success.
    function cancelOrder(
        address[2] orderAddresses,
        uint[6] orderValues,
        uint cancelAmount)
        public
        nonReentrant
        returns (bool)
    {
        Order memory order = Order({
            maker: orderAddresses[0],
            market: orderAddresses[1],
            outcome: orderValues[0],
            orderType: orderValues[1],
            amount: orderValues[2],
            price: orderValues[3],
            expirationTimestampInSec: orderValues[4],
            orderHash: getOrderHash(orderAddresses, orderValues)
        });

        require(order.maker == msg.sender);
        require(order.amount > 0 && cancelAmount > 0);

        if (controller.getTimestamp() >= order.expirationTimestampInSec) {
            Error(uint8(Errors.ORDER_EXPIRED), order.orderHash);
            return false;
        }

        uint remainingAmount = order.amount.sub(getUnavailableAmount(order.orderHash));
        uint cancelledAmount = cancelAmount.min(remainingAmount);
        if (cancelledAmount == 0) {
            Error(uint8(Errors.ORDER_FULLY_FILLED_OR_CANCELLED), order.orderHash);
            return false;
        }

        cancelled[order.orderHash] = cancelled[order.orderHash].add(cancelledAmount);

        Cancel(
            order.orderHash,
            cancelledAmount
        );

        return true;
    }

    /*
    * Constant public functions
    */

    /// @dev Calculates Keccak-256 hash of order with specified parameters.
    /// @param orderAddresses Array of order's maker and market.
    /// @param orderValues Array of order's outcome, orderType, amount, price, expirationTimestampInSec, and salt.
    /// @return Keccak-256 hash of order.
    function getOrderHash(address[2] orderAddresses, uint[6] orderValues)
        public
        constant
        returns (bytes32)
    {
        return keccak256(
            address(this),
            orderAddresses[0], // maker
            orderAddresses[1], // market
            orderValues[0],    // outcome
            orderValues[1],    // orderType
            orderValues[2],    // amount
            orderValues[3],    // price
            orderValues[4],    // expirationTimestampInSec
            orderValues[5]     // salt
        );
    }

    /// @dev Verifies that an order signature is valid.
    /// @param signer address of signer.
    /// @param hash Signed Keccak-256 hash.
    /// @param v ECDSA signature parameter v.
    /// @param r ECDSA signature parameters r.
    /// @param s ECDSA signature parameters s.
    /// @return Validity of order signature.
    function isValidSignature(
        address signer,
        bytes32 hash,
        uint8 v,
        bytes32 r,
        bytes32 s)
        public
        constant
        returns (bool)
    {
        return true;
        /*
        return signer == ecrecover(
            keccak256("\x19Ethereum Signed Message:\n32", hash),
            v,
            r,
            s
        );
        */
    }

    /// @dev Calculates the sum of values already filled and cancelled for a given order.
    /// @param orderHash The Keccak-256 hash of the given order.
    /// @return Sum of values already filled and cancelled.
    function getUnavailableAmount(bytes32 orderHash)
        public
        constant
        returns (uint)
    {
        return filled[orderHash].add(cancelled[orderHash]);
    }

    function getTokenBalance(ERC20 token, address owner)
        public
        view
        returns (uint)
    {
        return tokenBalances[token][owner];
    }

    /*
    * Internal functions
    */

    /// @dev Get token balance of an address.
    /// @param token Address of token.
    /// @param owner Address of owner.
    /// @return Token balance of owner.
    function getBalance(ERC20 token, address owner)
        internal
        constant  // The called token contract may attempt to change state, but will not be able to due to an added gas limit.
        returns (uint)
    {
        return token.balanceOf.gas(EXTERNAL_QUERY_GAS_LIMIT)(owner); // Limit gas to prevent reentrancy
    }

    /// @dev Get allowance of token given to this contract by an address.
    /// @param token Address of token.
    /// @param owner Address of owner.
    /// @return Allowance of token given to this contract by owner.
    function getAllowance(ERC20 token, address owner)
        internal
        constant  // The called token contract may attempt to change state, but will not be able to due to an added gas limit.
        returns (uint)
    {
        return token.allowance.gas(EXTERNAL_QUERY_GAS_LIMIT)(owner, this); // Limit gas to prevent reentrancy
    }
}
