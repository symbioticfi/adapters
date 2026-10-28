// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title TestnetToken
/// @notice Admin-issued token with explicit denomination and optional investor restrictions.
contract TestnetToken is ERC20, Ownable {
    error InvalidInvestor();

    uint8 internal immutable _DECIMALS;
    bool public restricted;
    mapping(address investor => bool allowed) public investors;

    event SetInvestor(address indexed investor, bool allowed);
    event SetRestricted(bool restricted);

    constructor(string memory newName, string memory newSymbol, uint8 newDecimals, address newOwner)
        ERC20(newName, newSymbol)
        Ownable(newOwner)
    {
        _DECIMALS = newDecimals;
    }

    function decimals() public view override returns (uint8) {
        return _DECIMALS;
    }

    function mint(address receiver, uint256 amount) public onlyOwner {
        _mint(receiver, amount);
    }

    function burn(uint256 amount) public {
        _burn(msg.sender, amount);
    }

    function setInvestor(address investor, bool allowed) public onlyOwner {
        investors[investor] = allowed;
        emit SetInvestor(investor, allowed);
    }

    function setRestricted(bool newRestricted) public onlyOwner {
        restricted = newRestricted;
        emit SetRestricted(newRestricted);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (restricted && ((from != address(0) && !investors[from]) || (to != address(0) && !investors[to]))) {
            revert InvalidInvestor();
        }
        super._update(from, to, value);
    }
}

/// @title TestnetPriceFeed
/// @notice Timestamped Chainlink rounds and the Midas data-feed ABI, with explicit freshness checks.
contract TestnetPriceFeed is Ownable {
    error InvalidPrice();
    error StalePrice();

    struct Round {
        int256 answer;
        uint48 timestamp;
    }
    uint8 public immutable decimals;
    string public description;
    uint256 public constant version = 1;
    uint48 public immutable maxAge;
    uint80 public latestRound;
    mapping(uint80 round => Round data) public rounds;

    event NewRound(uint256 indexed roundId, address indexed startedBy, uint256 startedAt);
    event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);

    constructor(address newOwner, string memory newDescription, uint8 newDecimals, uint48 newMaxAge, int256 price)
        Ownable(newOwner)
    {
        if (newDecimals > 18 || newMaxAge == 0) revert InvalidPrice();
        decimals = newDecimals;
        description = newDescription;
        maxAge = newMaxAge;
        _publish(price);
    }

    function aggregator() public view returns (address) {
        return address(this);
    }

    function publish(int256 price) public onlyOwner {
        _publish(price);
    }

    function latestAnswer() public view returns (int256) {
        return rounds[latestRound].answer;
    }

    function latestRoundData() public view returns (uint80, int256, uint256, uint256, uint80) {
        return getRoundData(latestRound);
    }

    function getRoundData(uint80 id) public view returns (uint80, int256, uint256, uint256, uint80) {
        Round memory round = rounds[id];
        if (round.timestamp == 0) revert InvalidPrice();
        return (id, round.answer, round.timestamp, round.timestamp, id);
    }

    function getDataInBase18() public view returns (uint256) {
        Round memory round = rounds[latestRound];
        if (block.timestamp - round.timestamp > maxAge) revert StalePrice();
        return uint256(round.answer) * 10 ** (18 - decimals);
    }

    function getPrice() public view returns (uint256) {
        return getDataInBase18();
    }

    function getPriceData() public view returns (uint256, uint48) {
        return (getDataInBase18(), rounds[latestRound].timestamp);
    }

    function _publish(int256 price) internal {
        if (price <= 0) revert InvalidPrice();
        ++latestRound;
        rounds[latestRound] = Round({answer: price, timestamp: uint48(block.timestamp)});
        emit NewRound(latestRound, msg.sender, block.timestamp);
        emit AnswerUpdated(price, latestRound, block.timestamp);
    }
}
