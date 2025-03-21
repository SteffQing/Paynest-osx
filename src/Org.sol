// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import {IPayments} from "./interfaces/IPayments.sol";
import {Owner} from "./util/Owner.sol";
import {Errors} from "./util/Errors.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IRegistry.sol";
import "./util/ReentrancyGuard.sol";
import "./lib/SafeTransferLib.sol";

/**
 * @title Org
 * @notice A contract that manages payment schedules and streams.
 */
contract Org is
    IPayments,
    Errors,
    Owner,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;
    IRegistry private immutable Registry =
        IRegistry(0xf75150d730CE97C1551e97df39c0A049024e4C25); // Need to manually set this

    address internal constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    uint40 private constant INTERVAL = uint40(30 days);
    uint40 private constant EDIT_TIMEOUT = uint40(3 days);

    mapping(string => Schedule) private schedulePayment;
    mapping(string => Stream) private streamPayment;

    constructor(address _owner, string memory _name) payable Owner(_owner) {}

    receive() external payable {}

    function createSchedule(
        string calldata username,
        uint256 amount,
        address token,
        uint40 oneTimePayoutDate
    ) external override {
        onlyOwner();
        Registry.getUserAddress(username);
        if (amount == 0) revert InvalidAmount();

        Schedule memory _schedule = schedulePayment[username];
        if (_schedule.active) revert ActivePayment(username);

        uint40 _now = uint40(block.timestamp);
        bool isOneTime = oneTimePayoutDate > _now;
        uint40 nextPayout = isOneTime ? oneTimePayoutDate : (_now + INTERVAL);

        schedulePayment[username] = Schedule(
            token,
            nextPayout,
            isOneTime,
            true,
            amount
        );
        emit ScheduleActive(username, token, nextPayout, amount);
    }

    function createStream(
        string calldata username,
        uint256 amount,
        address token,
        uint40 endStream
    ) external override {
        onlyOwner();
        Registry.getUserAddress(username);
        if (amount == 0) revert InvalidAmount();

        Stream memory _stream = streamPayment[username];
        if (_stream.active) revert ActivePayment(username);

        uint40 _now = uint40(block.timestamp);
        if (endStream <= _now) revert InvalidEndDate();

        streamPayment[username] = Stream({
            token: token,
            endDate: endStream,
            active: true,
            amount: amount,
            lastPayout: _now
        });
        emit StreamActive(username, token, endStream, amount);
    }

    function requestSchedulePayout(
        string calldata username
    ) external payable override nonReentrant {
        Schedule memory _schedule = schedulePayment[username];
        if (!_schedule.active) revert InActivePayment(username);

        uint40 currentTime = uint40(block.timestamp);
        if (currentTime < _schedule.nextPayout) revert NoPayoutDue();

        address recipient = Registry.getUserAddress(username);
        uint256 payoutAmount = _schedule.amount;

        if (_schedule.isOneTime) {
            schedulePayment[username].active = false;
        } else {
            uint40 nextPayout = _schedule.nextPayout + INTERVAL;

            // Ensure the next payout isn't set in the past and account for missed payouts
            if (nextPayout < currentTime) {
                uint40 missedIntervals = (currentTime - _schedule.nextPayout) /
                    INTERVAL;
                payoutAmount += _schedule.amount * missedIntervals;
                nextPayout =
                    _schedule.nextPayout +
                    (missedIntervals + 1) *
                    INTERVAL;
            }

            schedulePayment[username].nextPayout = nextPayout;
        }      

        if (_schedule.token == ETH)
            SafeTransferLib.safeTransferETH(recipient, payoutAmount);
        else
            SafeTransferLib.safeTransfer(
                ERC20(_schedule.token),
                recipient,
                payoutAmount
            );

        emit PaymentExecuted(username, _schedule.token, payoutAmount);
    }

    function _streamPayout(string calldata username) private {
        Stream memory _stream = streamPayment[username];
        if (!_stream.active) revert InActivePayment(username);

        uint40 currentTime = uint40(block.timestamp);

        address recipient = Registry.getUserAddress(username);
        uint256 payoutAmount;

        if (currentTime >= _stream.endDate) {
            uint40 timeUntilEnd = _stream.endDate - _stream.lastPayout;
            payoutAmount = timeUntilEnd * _stream.amount;
            streamPayment[username].active = false;
        } else {
            uint40 elapsedTime = currentTime - _stream.lastPayout;
            payoutAmount = elapsedTime * _stream.amount;
        }

        streamPayment[username].lastPayout = currentTime;

        if (_stream.token == ETH)
            SafeTransferLib.safeTransferETH(recipient, payoutAmount);
        else
            SafeTransferLib.safeTransfer(
                ERC20(_stream.token),
                recipient,
                payoutAmount
            );

        emit Payout(username, _stream.token, payoutAmount);
    }

    // function _incompleteSchedulePayout(string calldata username) private {
    //     Schedule memory _schedule = schedulePayment[username];
    //     if (!_schedule.active) revert InActivePayment(username);

    //     uint40 currentTime = uint40(block.timestamp);
    //     uint40 elapsedTime = currentTime -
    //         (_schedule.nextPayout - uint40(30 days));

    //     // Calculate the prorated payment amount
    //     uint256 proratedAmount = (elapsedTime * _schedule.amount) /
    //         uint40(30 days);

    //     address recipient = Registry.getUserAddress(username);
    //     if (proratedAmount > 0) {
    //         if (_schedule.token == Constants.ETH)
    //             SafeTransferLib.safeTransferETH(recipient, proratedAmount);
    //         else
    //             SafeTransferLib.safeTransfer(
    //                 ERC20(_schedule.token),
    //                 recipient,
    //                 proratedAmount
    //             );
    //         emit Payout(username, _schedule.token, proratedAmount);
    //     }
    // }

    function requestStreamPayout(
        string calldata username
    ) external payable override nonReentrant {
        _streamPayout(username);
    }

    function getStream(
        string calldata username
    ) external view override returns (Stream memory) {
        return streamPayment[username];
    }

    function getSchedule(
        string calldata username
    ) external view override returns (Schedule memory) {
        return schedulePayment[username];
    }

    function editSchedule(
        string calldata username,
        uint amount
    ) external override {
        onlyOwner();
        if (amount == 0) revert InvalidAmount();

        Schedule memory _schedule = schedulePayment[username];
        if (!_schedule.active) revert InActivePayment(username);

        uint40 currentTimestamp = uint40(block.timestamp);
        if ((_schedule.nextPayout - currentTimestamp) < EDIT_TIMEOUT)
            revert NoEditAccess();

        schedulePayment[username].amount = amount;
        emit ScheduleUpdated(username, amount);
    }

    function editStream(
        string calldata username,
        uint amount
    ) external override {
        onlyOwner();
        if (amount == 0) revert InvalidAmount();

        Stream memory _stream = streamPayment[username];
        if (!_stream.active) revert InActivePayment(username);

        streamPayment[username].amount = amount;
        emit StreamUpdated(username, amount);
    }

    function cancelSchedule(
        string calldata username
    ) external override {
        onlyOwner();
        // _incompleteSchedulePayout(username);

        schedulePayment[username].active = false;
        emit PaymentScheduleCancelled(username);
    }

    function cancelStream(
        string calldata username
    ) external override {
        onlyOwner();
        _streamPayout(username);

        streamPayment[username].active = false;
        emit PaymentStreamCancelled(username);
    }
}
