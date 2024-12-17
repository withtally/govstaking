// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.13;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {console} from "forge-std/console.sol";
import {AddressSet, LibAddressSet} from "../helpers/AddressSet.sol";
import {DepositIdSet, LibDepositIdSet} from "../helpers/DepositIdSet.sol";
import {GovernanceStaker} from "src/GovernanceStaker.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";

contract GovernanceStakerHandler is CommonBase, StdCheats, StdUtils {
  using LibAddressSet for AddressSet;
  using LibDepositIdSet for DepositIdSet;

  // system setup
  GovernanceStaker public govStaker;
  IERC20 public stakeToken;
  IERC20 public rewardToken;
  address public admin;

  // actors, deposit state
  address internal _currentActor;
  AddressSet internal _depositors;
  AddressSet internal _delegates;
  AddressSet internal _claimers;
  DepositIdSet internal _depositIdSet;
  AddressSet internal _surrogates;
  AddressSet internal _rewardNotifiers;
  mapping(address => uint256[]) internal _depositIds;
  mapping(bytes32 => uint256) public calls;

  // ghost vars
  uint256 public ghost_stakeSum;
  uint256 public ghost_stakeWithdrawn;
  uint256 public ghost_depositCount;
  uint256 public ghost_rewardsClaimed;
  uint256 public ghost_rewardsNotified;
  uint256 public ghost_prevRewardPerTokenAccumulatedCheckpoint;

  modifier countCall(bytes32 key) {
    calls[key]++;
    _;
  }

  modifier doCheckpoints() {
    _checkpoint_ghost_prevRewardPerTokenAccumulatedCheckpoint();
    _;
  }

  constructor(GovernanceStaker _govStaker) {
    govStaker = _govStaker;
    stakeToken = IERC20(address(_govStaker.STAKE_TOKEN()));
    rewardToken = IERC20(address(_govStaker.REWARD_TOKEN()));
    admin = govStaker.admin();
  }

  function _mintStakeToken(address _to, uint256 _amount) internal {
    vm.assume(_to != address(0));
    deal(address(stakeToken), _to, _amount, true);
  }

  function _mintRewardToken(address _to, uint256 _amount) internal {
    vm.assume(_to != address(0));
    deal(address(rewardToken), _to, _amount, true);
  }

  function enableRewardNotifier(address _notifier)
    public
    countCall("enableRewardNotifier")
    doCheckpoints
  {
    vm.assume(_notifier != address(0) && _notifier != address(govStaker));
    _rewardNotifiers.add(_notifier);
    vm.startPrank(admin);
    govStaker.setRewardNotifier(_notifier, true);
    vm.stopPrank();
  }

  function notifyRewardAmount(uint256 _amount, uint256 _actorSeed)
    public
    countCall("notifyRewardAmount")
    doCheckpoints
  {
    _useActor(_rewardNotifiers, _actorSeed);
    vm.assume(_currentActor != address(0));
    _amount = _bound(_amount, 0, 100_000_000e18);
    ghost_prevRewardPerTokenAccumulatedCheckpoint = govStaker.rewardPerTokenAccumulatedCheckpoint();
    _mintRewardToken(_currentActor, _amount);
    vm.startPrank(_currentActor);
    rewardToken.transfer(address(govStaker), _amount);
    govStaker.notifyRewardAmount(_amount);
    vm.stopPrank();
    ghost_rewardsNotified += _amount;
  }

  function stake(uint256 _amount, address _delegatee, address _claimer)
    public
    countCall("stake")
    doCheckpoints
  {
    _createDepositor();

    _claimers.add(_claimer);
    _delegates.add(_delegatee);
    _amount = uint256(_bound(_amount, 0, 100_000_000e18));

    // assume user has stake amount
    _mintStakeToken(_currentActor, _amount);

    vm.startPrank(_currentActor);
    stakeToken.approve(address(govStaker), _amount);
    govStaker.stake(_amount, _delegatee, _claimer);
    vm.stopPrank();

    // update handler state
    _depositIds[_currentActor].push(ghost_depositCount);
    _depositIdSet.add(GovernanceStaker.DepositIdentifier.wrap(ghost_depositCount));
    ghost_depositCount++;
    _surrogates.add(address(govStaker.surrogates(_delegatee)));
    ghost_stakeSum += _amount;
  }

  function validStakeMore(uint256 _amount, uint256 _actorSeed, uint256 _actorDepositSeed)
    public
    countCall("validStakeMore")
    doCheckpoints
  {
    _useActor(_depositors, _actorSeed);
    vm.assume(_currentActor != address(0));
    vm.assume(_depositIds[_currentActor].length > 0);
    GovernanceStaker.DepositIdentifier _depositId =
      GovernanceStaker.DepositIdentifier.wrap(_getActorRandDepositId(_actorDepositSeed));
    (uint256 _balance,,,,,,) = govStaker.deposits(_depositId);
    _amount = uint256(_bound(_amount, 0, _balance));
    vm.startPrank(_currentActor);
    stakeToken.approve(address(govStaker), _amount);
    govStaker.stakeMore(_depositId, _amount);
    vm.stopPrank();
    ghost_stakeSum += _amount;
  }

  function validWithdraw(uint256 _amount, uint256 _actorSeed, uint256 _actorDepositSeed)
    public
    countCall("validWithdraw")
    doCheckpoints
  {
    _useActor(_depositors, _actorSeed);
    vm.assume(_currentActor != address(0));
    vm.assume(_depositIds[_currentActor].length > 0);
    GovernanceStaker.DepositIdentifier _depositId =
      GovernanceStaker.DepositIdentifier.wrap(_getActorRandDepositId(_actorDepositSeed));
    (uint256 _balance,,,,,,) = govStaker.deposits(_depositId);
    _amount = uint256(_bound(_amount, 0, _balance));
    vm.startPrank(_currentActor);
    govStaker.withdraw(_depositId, _amount);
    vm.stopPrank();
    ghost_stakeWithdrawn += _amount;
  }

  function claimReward(uint256 _actorSeed, uint256 _actorDepositSeed)
    public
    countCall("claimReward")
    doCheckpoints
  {
    _useActor(_depositors, _actorSeed);
    vm.assume(_currentActor != address(0));
    vm.assume(_depositIds[_currentActor].length > 0);
    GovernanceStaker.DepositIdentifier _depositId =
      GovernanceStaker.DepositIdentifier.wrap(_getActorRandDepositId(_actorDepositSeed));
    vm.startPrank(_currentActor);
    uint256 rewardsClaimed = govStaker.claimReward(_depositId);
    vm.stopPrank();
    ghost_rewardsClaimed += rewardsClaimed;
  }

  function warpAhead(uint256 _seconds) public countCall("warpAhead") doCheckpoints {
    _seconds = _bound(_seconds, 0, govStaker.REWARD_DURATION() * 2);
    skip(_seconds);
  }

  function _getActorRandDepositId(uint256 _randomDepositSeed) internal view returns (uint256) {
    return _depositIds[_currentActor][_randomDepositSeed % _depositIds[_currentActor].length];
  }

  function _createDepositor() internal {
    _currentActor = msg.sender;
    // Surrogates can't stake. We won't include them as potential depositors.
    vm.assume(!_surrogates.contains(_currentActor));
    // GovStaker can't stake. We won't include it as a potential depositor.
    vm.assume(_currentActor != address(govStaker));
    _depositors.add(msg.sender);
  }

  function _useActor(AddressSet storage _set, uint256 _randomActorSeed) internal {
    _currentActor = _set.rand(_randomActorSeed);
  }

  function reduceDepositors(uint256 acc, function(uint256,address) external returns (uint256) func)
    public
    returns (uint256)
  {
    return _depositors.reduce(acc, func);
  }

  function reduceClaimers(uint256 acc, function(uint256,address) external returns (uint256) func)
    public
    returns (uint256)
  {
    return _claimers.reduce(acc, func);
  }

  function reduceDeposits(
    uint256 acc,
    function(uint256,GovernanceStaker.DepositIdentifier) external returns (uint256) func
  ) public returns (uint256) {
    return _depositIdSet.reduce(acc, func);
  }

  function reduceDelegates(uint256 acc, function(uint256,address) external returns (uint256) func)
    public
    returns (uint256)
  {
    return _delegates.reduce(acc, func);
  }

  function _checkpoint_ghost_prevRewardPerTokenAccumulatedCheckpoint() internal {
    ghost_prevRewardPerTokenAccumulatedCheckpoint = govStaker.rewardPerTokenAccumulatedCheckpoint();
  }

  function callSummary() external view {
    console.log("\nCall summary:");
    console.log("-------------------");
    console.log("stake", calls["stake"]);
    console.log("validStakeMore", calls["validStakeMore"]);
    console.log("validWithdraw", calls["validWithdraw"]);
    console.log("claimReward", calls["claimReward"]);
    console.log("enableRewardNotifier", calls["enableRewardNotifier"]);
    console.log("notifyRewardAmount", calls["notifyRewardAmount"]);
    console.log("warpAhead", calls["warpAhead"]);
    console.log("-------------------\n");
  }

  receive() external payable {}
}
