// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Blame Distribution Voting System (v1).
/// @dev Implements the rules defined in docs/spec-contract.md (source: PRDs).
contract BlameDistributionVoting is Ownable, ReentrancyGuard, Pausable {
  using SafeERC20 for IERC20;

  // ============
  // Errors
  // ============

  error InvalidOptionId();
  error InvalidAmount();
  error InvalidMaxVoters();
  error InvalidTokenAddress();
  error InvalidRecipient();
  error RoundNotScheduled();
  error RoundNotActive();
  error AlreadyVoted();
  error MaxVotersReached();
  error RoundNotEnded();
  error AlreadyFinalized();
  error CannotStartNewRound();
  error InvalidTimeRange();
  error EndTimeInPast();
  error ConfigLocked();
  error CannotRecoverVotingToken();
  error TransferFeeTokenNotSupported();
  error InvariantNoWinner();

  // ============
  // Events (normative)
  // ============

  event RoundStarted(uint256 indexed roundId, uint256 startTime, uint256 endTime);
  event Voted(
    uint256 indexed roundId,
    address indexed voter,
    uint256 indexed optionId,
    uint256 amount
  );
  event RoundFinalized(
    uint256 indexed roundId,
    uint256 scapegoatOptionId,
    uint256 totalPrizePool,
    uint256 winnerTotalVotes,
    uint256 winnerCount
  );
  event RewardDistributed(uint256 indexed roundId, address indexed winner, uint256 amount);

  event VotingTitleUpdated(string title);
  event OptionNamesUpdated(string[4] names);
  event MaxVotersPerRoundUpdated(uint256 maxVotersPerRound);
  event RoundMetadataUpdated(
    uint256 indexed roundId,
    string title,
    string roundDescription,
    string prizePoolRules
  );
  event OptionMetadataUpdated(
    uint256 indexed roundId,
    string[4] names,
    string[4] descriptions,
    string[4] avatarUrls
  );

  event RecoverERC20(address indexed token, address indexed to, uint256 amount);

  // ============
  // Storage
  // ============

  IERC20 public immutable votingToken;

  string public votingTitle;
  string[4] public optionNames;
  string public roundDescription;
  string public prizePoolRules;
  string[4] public optionDescriptions;
  string[4] public optionAvatarUrls;

  uint256 public currentRoundId;
  uint256 public maxVotersPerRound;

  // Current round state
  uint256 public startTime;
  uint256 public endTime;
  uint256 public totalPrizePool;
  uint256[4] public optionVotes;
  address[] public voters;
  bool public finalized;
  uint256 public scapegoatOptionId;

  struct Vote {
    uint8 optionId; // 0..3
    uint256 amount; // token raw units
  }

  // Round marker to avoid clearing mappings across rounds.
  mapping(address => uint256) private _votedRoundId;
  mapping(address => Vote) private _votes;

  struct RoundResult {
    uint256 roundId;
    uint8 scapegoatOptionId;
    string scapegoatOptionName;
    uint256 totalPrizePoolDistributed;
    uint256 winnerCount;
    uint256 roundEndTimestamp;
  }

  RoundResult public previousRoundResult;

  // ============
  // Constructor
  // ============

  constructor(
    IERC20 votingToken_,
    string memory initialTitle,
    string[4] memory initialOptionNames,
    uint256 initialMaxVotersPerRound
  ) Ownable(msg.sender) {
    if (address(votingToken_) == address(0)) revert InvalidTokenAddress();
    if (initialMaxVotersPerRound == 0) revert InvalidMaxVoters();

    votingToken = votingToken_;
    votingTitle = initialTitle;
    optionNames[0] = initialOptionNames[0];
    optionNames[1] = initialOptionNames[1];
    optionNames[2] = initialOptionNames[2];
    optionNames[3] = initialOptionNames[3];
    maxVotersPerRound = initialMaxVotersPerRound;
  }

  // ============
  // Views (frontend-required)
  // ============

  function getVotingTitle() external view returns (string memory) {
    return votingTitle;
  }

  function getVotingOptions() external view returns (string[4] memory) {
    return optionNames;
  }

  function getRoundMetadata()
    external
    view
    returns (string memory title, string memory description, string memory rules)
  {
    return (votingTitle, roundDescription, prizePoolRules);
  }

  function getOptionMetadata()
    external
    view
    returns (
      string[4] memory names,
      string[4] memory descriptions,
      string[4] memory avatarUrls
    )
  {
    return (optionNames, optionDescriptions, optionAvatarUrls);
  }

  function getVotingTime() external view returns (uint256 startTime_, uint256 endTime_) {
    return (startTime, endTime);
  }

  function getPrizePool() external view returns (uint256) {
    return totalPrizePool;
  }

  function getOptionVotes(uint256 optionId) external view returns (uint256) {
    if (optionId > 3) revert InvalidOptionId();
    return optionVotes[optionId];
  }

  function getVotingResults() external view returns (uint256[4] memory) {
    return optionVotes;
  }

  function hasVoted(address voter) public view returns (bool) {
    if (currentRoundId == 0) return false;
    return _votedRoundId[voter] == currentRoundId;
  }

  function getTotalVoters() external view returns (uint256) {
    return voters.length;
  }

  function getVoterInfo(
    address voter
  ) external view returns (bool voted, uint256 optionId, uint256 amount) {
    if (!hasVoted(voter)) return (false, 0, 0);
    Vote memory v = _votes[voter];
    return (true, uint256(v.optionId), v.amount);
  }

  function getPreviousRoundResults()
    external
    view
    returns (
      uint256 roundId,
      uint256 scapegoatOptionId_,
      string memory scapegoatOptionName,
      uint256 totalPrizePoolDistributed,
      uint256 winnerCount,
      uint256 roundEndTimestamp
    )
  {
    RoundResult memory r = previousRoundResult;
    return (
      r.roundId,
      uint256(r.scapegoatOptionId),
      r.scapegoatOptionName,
      r.totalPrizePoolDistributed,
      r.winnerCount,
      r.roundEndTimestamp
    );
  }

  // ============
  // User actions
  // ============

  function vote(uint256 optionId, uint256 amount) external nonReentrant whenNotPaused {
    _requireRoundActive();
    if (optionId > 3) revert InvalidOptionId();
    if (amount == 0) revert InvalidAmount();
    if (hasVoted(msg.sender)) revert AlreadyVoted();
    if (voters.length >= maxVotersPerRound) revert MaxVotersReached();

    // Enforce "standard token only": received amount must equal requested amount.
    uint256 balBefore = votingToken.balanceOf(address(this));
    votingToken.safeTransferFrom(msg.sender, address(this), amount);
    uint256 received = votingToken.balanceOf(address(this)) - balBefore;
    if (received != amount) revert TransferFeeTokenNotSupported();

    _votes[msg.sender] = Vote({optionId: uint8(optionId), amount: amount});
    _votedRoundId[msg.sender] = currentRoundId;

    optionVotes[optionId] += amount;
    totalPrizePool += amount;
    voters.push(msg.sender);

    emit Voted(currentRoundId, msg.sender, optionId, amount);
  }

  // ============
  // Admin actions
  // ============

  function startNewRound(
    uint256 startTime_,
    uint256 endTime_,
    string calldata title,
    string calldata roundDescription_,
    string calldata prizePoolRules_,
    string[4] calldata names,
    string[4] calldata descriptions,
    string[4] calldata avatarUrls
  ) external onlyOwner {
    if (currentRoundId != 0 && !finalized) revert CannotStartNewRound();
    if (startTime_ >= endTime_) revert InvalidTimeRange();
    if (endTime_ <= block.timestamp) revert EndTimeInPast();

    currentRoundId += 1;
    startTime = startTime_;
    endTime = endTime_;
    votingTitle = title;
    roundDescription = roundDescription_;
    prizePoolRules = prizePoolRules_;
    optionNames[0] = names[0];
    optionNames[1] = names[1];
    optionNames[2] = names[2];
    optionNames[3] = names[3];
    optionDescriptions[0] = descriptions[0];
    optionDescriptions[1] = descriptions[1];
    optionDescriptions[2] = descriptions[2];
    optionDescriptions[3] = descriptions[3];
    optionAvatarUrls[0] = avatarUrls[0];
    optionAvatarUrls[1] = avatarUrls[1];
    optionAvatarUrls[2] = avatarUrls[2];
    optionAvatarUrls[3] = avatarUrls[3];

    // Reset per-round aggregates (spec: reset in startNewRound to keep finalize lean).
    totalPrizePool = 0;
    optionVotes = [uint256(0), uint256(0), uint256(0), uint256(0)];
    delete voters;
    finalized = false;
    scapegoatOptionId = 0;

    emit RoundStarted(currentRoundId, startTime_, endTime_);
    emit RoundMetadataUpdated(currentRoundId, title, roundDescription_, prizePoolRules_);
    emit OptionMetadataUpdated(currentRoundId, names, descriptions, avatarUrls);
  }

  function finalizeAndDistribute() external onlyOwner nonReentrant {
    if (currentRoundId == 0) revert RoundNotScheduled();
    if (finalized) revert AlreadyFinalized();
    // Allow finalize if: time reached OR max voters reached
    if (block.timestamp <= endTime && voters.length < maxVotersPerRound) revert RoundNotEnded();

    _finalizeAndDistributeInternal();
  }

  /// @notice Force finalize the current round before it ends (owner only).
  /// @dev This allows emergency finalization without waiting for endTime or maxVoters.
  function forceFinalize() external onlyOwner nonReentrant {
    if (currentRoundId == 0) revert RoundNotScheduled();
    if (finalized) revert AlreadyFinalized();
    
    _finalizeAndDistributeInternal();
  }

  function _finalizeAndDistributeInternal() private {
    uint256 roundId = currentRoundId;

    uint256 pool = totalPrizePool;
    uint256 scapegoat = _selectScapegoat();
    scapegoatOptionId = scapegoat;

    // Edge case: 0 voters / 0 pool must finalize successfully.
    if (pool == 0) {
      finalized = true;
      previousRoundResult = RoundResult({
        roundId: roundId,
        scapegoatOptionId: uint8(scapegoat),
        scapegoatOptionName: optionNames[scapegoat],
        totalPrizePoolDistributed: 0,
        winnerCount: 0,
        roundEndTimestamp: endTime
      });
      emit RoundFinalized(roundId, scapegoat, 0, 0, 0);
      return;
    }

    uint256 winnerTotal = optionVotes[scapegoat];
    if (winnerTotal == 0) revert InvariantNoWinner();

    address lastWinner = address(0);
    uint256 winnerCount = 0;
    for (uint256 i = 0; i < voters.length; i++) {
      address v = voters[i];
      Vote memory vt = _votes[v];
      if (_votedRoundId[v] == roundId && vt.optionId == scapegoat) {
        lastWinner = v;
        winnerCount += 1;
      }
    }
    if (winnerCount == 0 || lastWinner == address(0)) revert InvariantNoWinner();

    uint256 distributed = 0;
    for (uint256 i = 0; i < voters.length; i++) {
      address w = voters[i];
      Vote memory vt = _votes[w];
      if (_votedRoundId[w] != roundId || vt.optionId != scapegoat) continue;
      if (w == lastWinner) continue;

      uint256 share = Math.mulDiv(vt.amount, pool, winnerTotal);
      distributed += share;
      votingToken.safeTransfer(w, share);
      emit RewardDistributed(roundId, w, share);
    }

    uint256 lastAmount = pool - distributed;
    votingToken.safeTransfer(lastWinner, lastAmount);
    emit RewardDistributed(roundId, lastWinner, lastAmount);

    finalized = true;
    previousRoundResult = RoundResult({
      roundId: roundId,
      scapegoatOptionId: uint8(scapegoat),
      scapegoatOptionName: optionNames[scapegoat],
      totalPrizePoolDistributed: pool,
      winnerCount: winnerCount,
      roundEndTimestamp: endTime
    });

    emit RoundFinalized(roundId, scapegoat, pool, winnerTotal, winnerCount);
  }

  function setVotingTitle(string calldata title) external onlyOwner {
    _requireConfigOpen();
    votingTitle = title;
    emit VotingTitleUpdated(title);
  }

  function setOptionNames(string[4] calldata names) external onlyOwner {
    _requireConfigOpen();
    // Avoid calldata->storage copy of nested dynamic types (strings) for compatibility with solc codegen.
    optionNames[0] = names[0];
    optionNames[1] = names[1];
    optionNames[2] = names[2];
    optionNames[3] = names[3];
    emit OptionNamesUpdated(names);
  }

  function setMaxVotersPerRound(uint256 maxVoters) external onlyOwner {
    _requireConfigOpen();
    if (maxVoters == 0) revert InvalidMaxVoters();
    maxVotersPerRound = maxVoters;
    emit MaxVotersPerRoundUpdated(maxVoters);
  }

  function pause() external onlyOwner {
    _pause();
  }

  function unpause() external onlyOwner {
    _unpause();
  }

  function recoverERC20(address token, address to, uint256 amount) external onlyOwner {
    if (token == address(votingToken)) revert CannotRecoverVotingToken();
    if (to == address(0)) revert InvalidRecipient();
    IERC20(token).safeTransfer(to, amount);
    emit RecoverERC20(token, to, amount);
  }

  // ============
  // Internal helpers
  // ============

  function _requireRoundActive() internal view {
    if (currentRoundId == 0) revert RoundNotScheduled();
    if (finalized) revert RoundNotActive();
    if (block.timestamp < startTime || block.timestamp > endTime) revert RoundNotActive();
  }

  function _requireConfigOpen() internal view {
    // Allowed when no round yet, or the current round hasn't started yet, or the round is finalized.
    if (currentRoundId == 0) return;
    if (finalized) return;
    if (block.timestamp < startTime) return;
    revert ConfigLocked();
  }

  function _selectScapegoat() internal view returns (uint256) {
    uint256 bestId = 0;
    uint256 bestVotes = optionVotes[0];
    for (uint256 i = 1; i < 4; i++) {
      uint256 v = optionVotes[i];
      if (v > bestVotes) {
        bestVotes = v;
        bestId = i;
      }
      // On tie, keep the smaller optionId (do nothing).
    }
    return bestId;
  }
}
