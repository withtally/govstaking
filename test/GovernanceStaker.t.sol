// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.23;

import {Vm, Test, stdStorage, StdStorage, console2, stdError} from "forge-std/Test.sol";
import {GovernanceStaker, IERC20, IEarningPowerCalculator} from "src/GovernanceStaker.sol";
import {IERC20Staking} from "src/interfaces/IERC20Staking.sol";
import {DelegationSurrogate} from "src/DelegationSurrogate.sol";
import {GovernanceStakerHarness} from "test/harnesses/GovernanceStakerHarness.sol";
import {GovernanceStakerOnBehalf} from "src/extensions/GovernanceStakerOnBehalf.sol";
import {ERC20VotesMock, ERC20Permit} from "test/mocks/MockERC20Votes.sol";
import {IERC20Errors} from "openzeppelin/interfaces/draft-IERC6093.sol";
import {ERC20Fake} from "test/fakes/ERC20Fake.sol";
import {MockFullEarningPowerCalculator} from "test/mocks/MockFullEarningPowerCalculator.sol";
import {PercentAssertions} from "test/helpers/PercentAssertions.sol";

contract GovernanceStakerTest is Test, PercentAssertions {
  ERC20Fake rewardToken;
  ERC20VotesMock govToken;
  MockFullEarningPowerCalculator earningPowerCalculator;

  address admin;
  address rewardNotifier;
  GovernanceStakerHarness govStaker;
  uint256 SCALE_FACTOR;
  // console2.log(uint(_domainSeparatorV4()))
  bytes32 EIP712_DOMAIN_SEPARATOR = bytes32(
    uint256(
      100_848_718_687_569_044_464_352_297_364_979_714_567_529_445_102_133_191_562_407_938_263_844_493_123_852
    )
  );
  uint256 maxBumpTip = 1e18;

  bytes32 constant PERMIT_TYPEHASH =
    keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

  event RewardNotifierSet(address indexed account, bool isEnabled);
  event AdminSet(address indexed oldAdmin, address indexed newAdmin);

  mapping(DelegationSurrogate surrogate => bool isKnown) isKnownSurrogate;
  mapping(address depositor => bool isKnown) isKnownDepositor;

  function setUp() public virtual {
    // Set the block timestamp to an arbitrary value to avoid introducing assumptions into tests
    // based on a starting timestamp of 0, which is the default.
    _jumpAhead(1234);

    rewardToken = new ERC20Fake();
    vm.label(address(rewardToken), "Reward Token");

    govToken = new ERC20VotesMock();
    vm.label(address(govToken), "Governance Token");

    rewardNotifier = address(0xaffab1ebeef);
    vm.label(rewardNotifier, "Reward Notifier");

    earningPowerCalculator = new MockFullEarningPowerCalculator();
    vm.label(address(earningPowerCalculator), "Full Earning Power Calculator");

    admin = makeAddr("admin");

    govStaker = new GovernanceStakerHarness(
      rewardToken, govToken, earningPowerCalculator, maxBumpTip, admin, "GovernanceStaker"
    );
    vm.label(address(govStaker), "GovStaker");

    vm.prank(admin);
    govStaker.setRewardNotifier(rewardNotifier, true);

    // Convenience for use in tests
    SCALE_FACTOR = govStaker.SCALE_FACTOR();
  }

  function _min(uint256 _leftValue, uint256 _rightValue) internal pure returns (uint256) {
    return _leftValue > _rightValue ? _rightValue : _leftValue;
  }

  function _jumpAhead(uint256 _seconds) public {
    vm.warp(block.timestamp + _seconds);
  }

  function _boundMintAmount(uint256 _amount) internal pure returns (uint256) {
    return bound(_amount, 0, 100_000_000e18);
  }

  function _mintGovToken(address _to, uint256 _amount) internal {
    vm.assume(_to != address(0));
    govToken.mint(_to, _amount);
  }

  function _boundToRealisticStake(uint256 _stakeAmount)
    public
    pure
    returns (uint256 _boundedStakeAmount)
  {
    _boundedStakeAmount = bound(_stakeAmount, 0.1e18, 25_000_000e18);
  }

  // Remember each depositor and surrogate (as they're deployed) and ensure that there is
  // no overlap between them. This is to prevent the fuzzer from selecting a surrogate as a
  // depositor or vice versa.
  function _assumeSafeDepositorAndSurrogate(address _depositor, address _delegatee) internal {
    DelegationSurrogate _surrogate = govStaker.surrogates(_delegatee);
    isKnownDepositor[_depositor] = true;
    isKnownSurrogate[_surrogate] = true;

    vm.assume(
      (!isKnownSurrogate[DelegationSurrogate(_depositor)])
        && (!isKnownDepositor[address(_surrogate)])
    );
  }

  function _setClaimFeeAndCollector(uint96 _amount, address _collector) internal {
    GovernanceStaker.ClaimFeeParameters memory _params =
      GovernanceStaker.ClaimFeeParameters({feeAmount: _amount, feeCollector: _collector});

    vm.prank(admin);
    govStaker.setClaimFeeParameters(_params);
  }

  function _stake(address _depositor, uint256 _amount, address _delegatee)
    internal
    returns (GovernanceStaker.DepositIdentifier _depositId)
  {
    vm.assume(_delegatee != address(0));

    vm.startPrank(_depositor);
    govToken.approve(address(govStaker), _amount);
    _depositId = govStaker.stake(_amount, _delegatee);
    vm.stopPrank();

    // Called after the stake so the surrogate will exist
    _assumeSafeDepositorAndSurrogate(_depositor, _delegatee);
  }

  function _stake(address _depositor, uint256 _amount, address _delegatee, address _claimer)
    internal
    returns (GovernanceStaker.DepositIdentifier _depositId)
  {
    vm.assume(_delegatee != address(0) && _claimer != address(0));

    vm.startPrank(_depositor);
    govToken.approve(address(govStaker), _amount);
    _depositId = govStaker.stake(_amount, _delegatee, _claimer);
    vm.stopPrank();

    // Called after the stake so the surrogate will exist
    _assumeSafeDepositorAndSurrogate(_depositor, _delegatee);
  }

  function _fetchDeposit(GovernanceStaker.DepositIdentifier _depositId)
    internal
    view
    returns (GovernanceStaker.Deposit memory)
  {
    (
      uint96 _balance,
      address _owner,
      uint96 _earningPower,
      address _delegatee,
      address _claimer,
      uint256 _rewardPerTokenCheckpoint,
      uint256 _scaledUnclaimedRewardCheckpoint
    ) = govStaker.deposits(_depositId);
    return GovernanceStaker.Deposit({
      balance: _balance,
      owner: _owner,
      delegatee: _delegatee,
      claimer: _claimer,
      earningPower: _earningPower,
      rewardPerTokenCheckpoint: _rewardPerTokenCheckpoint,
      scaledUnclaimedRewardCheckpoint: _scaledUnclaimedRewardCheckpoint
    });
  }

  function _boundMintAndStake(address _depositor, uint256 _amount, address _delegatee)
    internal
    returns (uint256 _boundedAmount, GovernanceStaker.DepositIdentifier _depositId)
  {
    _boundedAmount = _boundMintAmount(_amount);
    _mintGovToken(_depositor, _boundedAmount);
    _depositId = _stake(_depositor, _boundedAmount, _delegatee);
  }

  function _boundMintAndStake(
    address _depositor,
    uint256 _amount,
    address _delegatee,
    address _claimer
  ) internal returns (uint256 _boundedAmount, GovernanceStaker.DepositIdentifier _depositId) {
    _boundedAmount = _boundMintAmount(_amount);
    _mintGovToken(_depositor, _boundedAmount);
    _depositId = _stake(_depositor, _boundedAmount, _delegatee, _claimer);
  }

  // Scales first param and divides it by second
  function _scaledDiv(uint256 _x, uint256 _y) public view returns (uint256) {
    return (_x * SCALE_FACTOR) / _y;
  }

  function _sign(uint256 _privateKey, bytes32 _messageHash) internal pure returns (bytes memory) {
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_privateKey, _messageHash);
    return abi.encodePacked(_r, _s, _v);
  }

  function _modifyMessage(bytes32 _message, uint256 _index) internal pure returns (bytes32) {
    _index = bound(_index, 0, 31);
    bytes memory _messageBytes = abi.encodePacked(_message);
    // zero out the byte at the given index, or set it to 1 if it's already zero
    if (_messageBytes[_index] == 0) _messageBytes[_index] = bytes1(uint8(1));
    else _messageBytes[_index] = bytes1(uint8(0));
    return bytes32(_messageBytes);
  }

  function _modifySignature(bytes memory _signature, uint256 _index)
    internal
    pure
    returns (bytes memory)
  {
    _index = bound(_index, 0, _signature.length - 1);
    // zero out the byte at the given index, or set it to 1 if it's already zero
    if (_signature[_index] == 0) _signature[_index] = bytes1(uint8(1));
    else _signature[_index] = bytes1(uint8(0));
    return _signature;
  }
}

contract Constructor is GovernanceStakerTest {
  function test_SetsInitializationParameters() public view {
    assertEq(address(govStaker.REWARD_TOKEN()), address(rewardToken));
    assertEq(address(govStaker.STAKE_TOKEN()), address(govToken));
    assertEq(address(govStaker.earningPowerCalculator()), address(earningPowerCalculator));
    assertEq(govStaker.admin(), admin);
  }

  function testFuzz_SetsTheRewardTokenStakeTokenAndOwnerToArbitraryAddresses(
    address _rewardToken,
    address _stakeToken,
    address _earningPowerCalculator,
    uint256 _maxBumpTip,
    address _admin,
    string memory _name
  ) public {
    vm.assume(_admin != address(0) && _earningPowerCalculator != address(0));
    GovernanceStakerHarness _govStaker = new GovernanceStakerHarness(
      IERC20(_rewardToken),
      IERC20Staking(_stakeToken),
      IEarningPowerCalculator(_earningPowerCalculator),
      _maxBumpTip,
      _admin,
      _name
    );
    assertEq(address(_govStaker.REWARD_TOKEN()), address(_rewardToken));
    assertEq(address(_govStaker.STAKE_TOKEN()), address(_stakeToken));
    assertEq(address(_govStaker.earningPowerCalculator()), address(_earningPowerCalculator));
    assertEq(_govStaker.maxBumpTip(), _maxBumpTip);
    assertEq(_govStaker.admin(), _admin);
  }
}

contract Stake is GovernanceStakerTest {
  function testFuzz_DeploysAndTransfersTokensToANewSurrogateWhenAnAccountStakes(
    address _depositor,
    uint256 _amount,
    address _delegatee
  ) public {
    _amount = bound(_amount, 1, type(uint96).max);
    _mintGovToken(_depositor, _amount);
    _stake(_depositor, _amount, _delegatee);

    DelegationSurrogate _surrogate = govStaker.surrogates(_delegatee);

    assertEq(govToken.balanceOf(address(_surrogate)), _amount);
    assertEq(govToken.delegates(address(_surrogate)), _delegatee);
    assertEq(govToken.balanceOf(_depositor), 0);
  }

  function testFuzz_SetsDepositorAsClaimerWhenStakingWithoutASpecifiedClaimer(
    address _depositor,
    uint256 _amount,
    address _delegatee
  ) public {
    vm.assume(_delegatee != address(0));
    _amount = bound(_amount, 1, type(uint96).max);
    _mintGovToken(_depositor, _amount);
    vm.startPrank(_depositor);
    govToken.approve(address(govStaker), _amount);

    GovernanceStaker.DepositIdentifier _depositId = _stake(_depositor, _amount, _delegatee);

    GovernanceStaker.Deposit memory _deposit = _fetchDeposit(_depositId);
    assertEq(_deposit.claimer, _depositor);
  }

  function testFuzz_EmitsAStakingDepositEventWhenStakingWithoutASpecifiedClaimer(
    address _depositor,
    uint256 _amount,
    address _delegatee
  ) public {
    _amount = bound(_amount, 1, type(uint96).max);
    _mintGovToken(_depositor, _amount);
    GovernanceStaker.DepositIdentifier depositId = govStaker.exposed_useDepositId();

    vm.assume(_delegatee != address(0));

    vm.startPrank(_depositor);
    govToken.approve(address(govStaker), _amount);
    vm.expectEmit();
    emit GovernanceStaker.StakeDeposited(
      _depositor,
      GovernanceStaker.DepositIdentifier.wrap(
        GovernanceStaker.DepositIdentifier.unwrap(depositId) + 1
      ),
      _amount,
      _amount
    );

    govStaker.stake(_amount, _delegatee);
    vm.stopPrank();
  }

  function testFuzz_EmitsAClaimerAlteredEventWhenStakingWithoutASpecifiedClaimer(
    address _depositor,
    uint256 _amount,
    address _delegatee
  ) public {
    _amount = bound(_amount, 1, type(uint96).max);
    _mintGovToken(_depositor, _amount);
    GovernanceStaker.DepositIdentifier depositId = govStaker.exposed_useDepositId();

    vm.assume(_delegatee != address(0));

    vm.startPrank(_depositor);
    govToken.approve(address(govStaker), _amount);
    vm.expectEmit();
    emit GovernanceStaker.ClaimerAltered(
      GovernanceStaker.DepositIdentifier.wrap(
        GovernanceStaker.DepositIdentifier.unwrap(depositId) + 1
      ),
      address(0),
      _depositor
    );

    govStaker.stake(_amount, _delegatee);
    vm.stopPrank();
  }

  function testFuzz_EmitsADelegateeAlteredEventWhenStakingWithoutASpecifiedClaimer(
    address _depositor,
    uint256 _amount,
    address _delegatee
  ) public {
    _amount = bound(_amount, 1, type(uint96).max);
    _mintGovToken(_depositor, _amount);
    GovernanceStaker.DepositIdentifier depositId = govStaker.exposed_useDepositId();

    vm.assume(_delegatee != address(0));

    vm.startPrank(_depositor);
    govToken.approve(address(govStaker), _amount);
    vm.expectEmit();
    emit GovernanceStaker.DelegateeAltered(
      GovernanceStaker.DepositIdentifier.wrap(
        GovernanceStaker.DepositIdentifier.unwrap(depositId) + 1
      ),
      address(0),
      _delegatee
    );

    govStaker.stake(_amount, _delegatee);
    vm.stopPrank();
  }

  function testFuzz_SetsClaimerCorrectlyWhenStakingWithASpecifiedClaimer(
    address _depositor,
    uint256 _amount,
    address _delegatee,
    address _claimer
  ) public {
    vm.assume(_delegatee != address(0) && _claimer != address(0));
    _amount = uint256(bound(_amount, 1, type(uint96).max));
    _mintGovToken(_depositor, _amount);
    vm.startPrank(_depositor);
    govToken.approve(address(govStaker), _amount);

    GovernanceStaker.DepositIdentifier _depositId =
      _stake(_depositor, _amount, _delegatee, _claimer);

    GovernanceStaker.Deposit memory _deposit = _fetchDeposit(_depositId);
    assertEq(_deposit.claimer, _claimer);
  }

  function testFuzz_EmitsAStakingDepositEventWhenStakingWithASpecifiedClaimer(
    address _depositor,
    uint256 _amount,
    address _delegatee,
    address _claimer
  ) public {
    _amount = bound(_amount, 1, type(uint96).max);
    _mintGovToken(_depositor, _amount);
    GovernanceStaker.DepositIdentifier depositId = govStaker.exposed_useDepositId();

    vm.assume(_delegatee != address(0) && _claimer != address(0));

    vm.startPrank(_depositor);
    govToken.approve(address(govStaker), _amount);
    vm.expectEmit();
    emit GovernanceStaker.StakeDeposited(
      _depositor,
      GovernanceStaker.DepositIdentifier.wrap(
        GovernanceStaker.DepositIdentifier.unwrap(depositId) + 1
      ),
      _amount,
      _amount
    );

    govStaker.stake(_amount, _delegatee, _claimer);
    vm.stopPrank();
  }

  function testFuzz_EmitsAClaimerAlteredEventWhenStakingWithASpecifiedClaimer(
    address _depositor,
    uint256 _amount,
    address _delegatee,
    address _claimer
  ) public {
    _amount = bound(_amount, 1, type(uint96).max);
    _mintGovToken(_depositor, _amount);
    GovernanceStaker.DepositIdentifier depositId = govStaker.exposed_useDepositId();

    vm.assume(_delegatee != address(0) && _claimer != address(0));

    vm.startPrank(_depositor);
    govToken.approve(address(govStaker), _amount);
    vm.expectEmit();
    emit GovernanceStaker.ClaimerAltered(
      GovernanceStaker.DepositIdentifier.wrap(
        GovernanceStaker.DepositIdentifier.unwrap(depositId) + 1
      ),
      address(0),
      _claimer
    );

    govStaker.stake(_amount, _delegatee, _claimer);
    vm.stopPrank();
  }

  function testFuzz_EmitsADelegateeAlteredEventWhenStakingWithASpecifiedClaimer(
    address _depositor,
    uint256 _amount,
    address _delegatee,
    address _claimer
  ) public {
    _amount = bound(_amount, 1, type(uint96).max);
    _mintGovToken(_depositor, _amount);
    GovernanceStaker.DepositIdentifier depositId = govStaker.exposed_useDepositId();

    vm.assume(_delegatee != address(0) && _claimer != address(0));

    vm.startPrank(_depositor);
    govToken.approve(address(govStaker), _amount);
    vm.expectEmit();
    emit GovernanceStaker.DelegateeAltered(
      GovernanceStaker.DepositIdentifier.wrap(
        GovernanceStaker.DepositIdentifier.unwrap(depositId) + 1
      ),
      address(0),
      _delegatee
    );

    govStaker.stake(_amount, _delegatee, _claimer);
    vm.stopPrank();
  }

  function testFuzz_TransfersToAnExistingSurrogateWhenStakedToTheSameDelegatee(
    address _depositor1,
    uint256 _amount1,
    address _depositor2,
    uint256 _amount2,
    address _delegatee
  ) public {
    _amount1 = _boundMintAmount(_amount1);
    _amount2 = _boundMintAmount(_amount2);
    _mintGovToken(_depositor1, _amount1);
    _mintGovToken(_depositor2, _amount2);

    // Perform first stake with this delegatee
    _stake(_depositor1, _amount1, _delegatee);
    // Remember the surrogate which was deployed for this delegatee
    DelegationSurrogate _surrogate = govStaker.surrogates(_delegatee);

    // Perform the second stake with this delegatee
    _stake(_depositor2, _amount2, _delegatee);

    // Ensure surrogate for this delegatee hasn't changed and has summed stake balance
    assertEq(address(govStaker.surrogates(_delegatee)), address(_surrogate));
    assertEq(govToken.delegates(address(_surrogate)), _delegatee);
    assertEq(govToken.balanceOf(address(_surrogate)), _amount1 + _amount2);
    assertEq(govToken.balanceOf(_depositor1), 0);
    assertEq(govToken.balanceOf(_depositor2), 0);
  }

  function testFuzz_DeploysAndTransfersTokenToTwoSurrogatesWhenAccountsStakesToDifferentDelegatees(
    address _depositor1,
    uint256 _amount1,
    address _depositor2,
    uint256 _amount2,
    address _delegatee1,
    address _delegatee2
  ) public {
    vm.assume(_delegatee1 != _delegatee2);
    _amount1 = _boundMintAmount(_amount1);
    _amount2 = _boundMintAmount(_amount2);
    _mintGovToken(_depositor1, _amount1);
    _mintGovToken(_depositor2, _amount2);

    // Perform first stake with first delegatee
    _stake(_depositor1, _amount1, _delegatee1);
    // Remember the surrogate which was deployed for first delegatee
    DelegationSurrogate _surrogate1 = govStaker.surrogates(_delegatee1);

    // Perform second stake with second delegatee
    _stake(_depositor2, _amount2, _delegatee2);
    // Remember the surrogate which was deployed for first delegatee
    DelegationSurrogate _surrogate2 = govStaker.surrogates(_delegatee2);

    // Ensure surrogates are different with discreet delegation & balances
    assertTrue(_surrogate1 != _surrogate2);
    assertEq(govToken.delegates(address(_surrogate1)), _delegatee1);
    assertEq(govToken.balanceOf(address(_surrogate1)), _amount1);
    assertEq(govToken.delegates(address(_surrogate2)), _delegatee2);
    assertEq(govToken.balanceOf(address(_surrogate2)), _amount2);
    assertEq(govToken.balanceOf(_depositor1), 0);
    assertEq(govToken.balanceOf(_depositor2), 0);
  }

  function testFuzz_UpdatesTheTotalStakedWhenAnAccountStakes(
    address _depositor,
    uint256 _amount,
    address _delegatee
  ) public {
    _amount = _boundMintAmount(_amount);
    _mintGovToken(_depositor, _amount);

    _stake(_depositor, _amount, _delegatee);

    assertEq(govStaker.totalStaked(), _amount);
  }

  function testFuzz_UpdatesTheTotalStakedWhenTwoAccountsStake(
    address _depositor1,
    uint256 _amount1,
    address _depositor2,
    uint256 _amount2,
    address _delegatee1,
    address _delegatee2
  ) public {
    _amount1 = _boundMintAmount(_amount1);
    _amount2 = _boundMintAmount(_amount2);
    _mintGovToken(_depositor1, _amount1);
    _mintGovToken(_depositor2, _amount2);

    _stake(_depositor1, _amount1, _delegatee1);
    assertEq(govStaker.totalStaked(), _amount1);

    _stake(_depositor2, _amount2, _delegatee2);
    assertEq(govStaker.totalStaked(), _amount1 + _amount2);
  }

  function testFuzz_UpdatesAnAccountsTotalStakedAccounting(
    address _depositor,
    uint256 _amount1,
    uint256 _amount2,
    address _delegatee1,
    address _delegatee2
  ) public {
    _amount1 = _boundMintAmount(_amount1);
    _amount2 = _boundMintAmount(_amount2);
    _mintGovToken(_depositor, _amount1 + _amount2);

    // First stake + check total
    _stake(_depositor, _amount1, _delegatee1);
    assertEq(govStaker.depositorTotalStaked(_depositor), _amount1);

    // Second stake + check total
    _stake(_depositor, _amount2, _delegatee2);
    assertEq(govStaker.depositorTotalStaked(_depositor), _amount1 + _amount2);
  }

  function testFuzz_UpdatesDifferentAccountsTotalStakedAccountingIndependently(
    address _depositor1,
    uint256 _amount1,
    address _depositor2,
    uint256 _amount2,
    address _delegatee1,
    address _delegatee2
  ) public {
    vm.assume(_depositor1 != _depositor2);
    _amount1 = _boundMintAmount(_amount1);
    _amount2 = _boundMintAmount(_amount2);
    _mintGovToken(_depositor1, _amount1);
    _mintGovToken(_depositor2, _amount2);

    _stake(_depositor1, _amount1, _delegatee1);
    assertEq(govStaker.depositorTotalStaked(_depositor1), _amount1);

    _stake(_depositor2, _amount2, _delegatee2);
    assertEq(govStaker.depositorTotalStaked(_depositor2), _amount2);
  }

  function testFuzz_UpdatesAnAccountsTotalEarningPower(
    address _depositor,
    uint256 _amount1,
    uint256 _amount2,
    address _delegatee1,
    address _delegatee2
  ) public {
    _amount1 = _boundMintAmount(_amount1);
    _amount2 = _boundMintAmount(_amount2);
    _mintGovToken(_depositor, _amount1 + _amount2);

    // First stake + check total
    _stake(_depositor, _amount1, _delegatee1);
    assertEq(govStaker.depositorTotalEarningPower(_depositor), _amount1);

    // Second stake + check total
    _stake(_depositor, _amount2, _delegatee2);
    assertEq(govStaker.depositorTotalEarningPower(_depositor), _amount1 + _amount2);
  }

  function testFuzz_UpdatesDifferentAccountsTotalEarningPowerIndependently(
    address _depositor1,
    uint256 _amount1,
    address _depositor2,
    uint256 _amount2,
    address _delegatee1,
    address _delegatee2
  ) public {
    vm.assume(_depositor1 != _depositor2);
    _amount1 = _boundMintAmount(_amount1);
    _amount2 = _boundMintAmount(_amount2);
    _mintGovToken(_depositor1, _amount1);
    _mintGovToken(_depositor2, _amount2);

    _stake(_depositor1, _amount1, _delegatee1);
    assertEq(govStaker.depositorTotalEarningPower(_depositor1), _amount1);

    _stake(_depositor2, _amount2, _delegatee2);
    assertEq(govStaker.depositorTotalEarningPower(_depositor2), _amount2);
  }

  function testFuzz_TracksTheBalanceForASpecificDeposit(
    address _depositor,
    uint256 _amount,
    address _delegatee
  ) public {
    _amount = _boundMintAmount(_amount);
    _mintGovToken(_depositor, _amount);

    GovernanceStaker.DepositIdentifier _depositId = _stake(_depositor, _amount, _delegatee);
    GovernanceStaker.Deposit memory _deposit = _fetchDeposit(_depositId);
    assertEq(_deposit.balance, _amount);
    assertEq(_deposit.owner, _depositor);
    assertEq(_deposit.delegatee, _delegatee);
  }

  function testFuzz_TracksTheBalanceForDifferentDepositsFromTheSameAccountIndependently(
    address _depositor,
    uint256 _amount1,
    uint256 _amount2,
    address _delegatee1,
    address _delegatee2
  ) public {
    _amount1 = _boundMintAmount(_amount1);
    _amount2 = _boundMintAmount(_amount2);
    _mintGovToken(_depositor, _amount1 + _amount2);

    // Perform both deposits and track their identifiers separately
    GovernanceStaker.DepositIdentifier _depositId1 = _stake(_depositor, _amount1, _delegatee1);
    GovernanceStaker.DepositIdentifier _depositId2 = _stake(_depositor, _amount2, _delegatee2);
    GovernanceStaker.Deposit memory _deposit1 = _fetchDeposit(_depositId1);
    GovernanceStaker.Deposit memory _deposit2 = _fetchDeposit(_depositId2);

    // Check that the deposits have been recorded independently
    assertEq(_deposit1.balance, _amount1);
    assertEq(_deposit1.owner, _depositor);
    assertEq(_deposit1.delegatee, _delegatee1);
    assertEq(_deposit2.balance, _amount2);
    assertEq(_deposit2.owner, _depositor);
    assertEq(_deposit2.delegatee, _delegatee2);
  }

  function testFuzz_TracksTheBalanceForDepositsFromDifferentAccountsIndependently(
    address _depositor1,
    address _depositor2,
    uint256 _amount1,
    uint256 _amount2,
    address _delegatee1,
    address _delegatee2
  ) public {
    _amount1 = _boundMintAmount(_amount1);
    _amount2 = _boundMintAmount(_amount2);
    _mintGovToken(_depositor1, _amount1);
    _mintGovToken(_depositor2, _amount2);

    // Perform both deposits and track their identifiers separately
    GovernanceStaker.DepositIdentifier _depositId1 = _stake(_depositor1, _amount1, _delegatee1);
    GovernanceStaker.DepositIdentifier _depositId2 = _stake(_depositor2, _amount2, _delegatee2);
    GovernanceStaker.Deposit memory _deposit1 = _fetchDeposit(_depositId1);
    GovernanceStaker.Deposit memory _deposit2 = _fetchDeposit(_depositId2);

    // Check that the deposits have been recorded independently
    assertEq(_deposit1.balance, _amount1);
    assertEq(_deposit1.owner, _depositor1);
    assertEq(_deposit1.delegatee, _delegatee1);
    assertEq(_deposit2.balance, _amount2);
    assertEq(_deposit2.owner, _depositor2);
    assertEq(_deposit2.delegatee, _delegatee2);
  }

  mapping(GovernanceStaker.DepositIdentifier depositId => bool isUsed) isIdUsed;

  function test_NeverReusesADepositIdentifier() public {
    address _depositor = address(0xdeadbeef);
    uint256 _amount = 116;
    address _delegatee = address(0xaceface);

    GovernanceStaker.DepositIdentifier _depositId;

    vm.pauseGasMetering();

    // Repeat the deposit over and over ensuring a new DepositIdentifier is assigned each time.
    for (uint256 _i; _i < 100; _i++) {
      // Perform the stake and save the deposit identifier
      _mintGovToken(_depositor, _amount);
      _depositId = _stake(_depositor, _amount, _delegatee);

      // Ensure the identifier hasn't yet been used
      assertFalse(isIdUsed[_depositId]);
      // Record the fact this deposit Id has been used
      isIdUsed[_depositId] = true;
    }

    // Now make a bunch more deposits with different depositors and parameters, continuing to check
    // that the DepositIdentifier is never reused.
    for (uint256 _i; _i < 100; _i++) {
      // Perform the stake and save the deposit identifier
      _amount = _bound(_amount, 0, type(uint96).max);
      _mintGovToken(_depositor, _amount);
      _depositId = _stake(_depositor, _amount, _delegatee);

      // Ensure the identifier hasn't yet been used
      assertFalse(isIdUsed[_depositId]);
      // Record the fact this deposit Id has been used
      isIdUsed[_depositId] = true;

      // Assign new inputs for the next deposit by hashing the last inputs
      _depositor = address(uint160(uint256(keccak256(abi.encode(_depositor)))));
      _amount = uint256(keccak256(abi.encode(_amount)));
      _delegatee = address(uint160(uint256(keccak256(abi.encode(_delegatee)))));
    }
  }

  function testFuzz_RevertIf_DelegateeIsTheZeroAddress(address _depositor, uint256 _amount) public {
    _amount = _boundMintAmount(_amount);
    _mintGovToken(_depositor, _amount);
    govToken.approve(address(govStaker), _amount);

    vm.prank(_depositor);
    vm.expectRevert(GovernanceStaker.GovernanceStaker__InvalidAddress.selector);
    govStaker.stake(_amount, address(0));
  }

  function testFuzz_RevertIf_ClaimerIsTheZeroAddress(
    address _depositor,
    uint256 _amount,
    address _delegatee
  ) public {
    vm.assume(_delegatee != address(0));

    _amount = _boundMintAmount(_amount);
    _mintGovToken(_depositor, _amount);
    govToken.approve(address(govStaker), _amount);

    vm.prank(_depositor);
    vm.expectRevert(GovernanceStaker.GovernanceStaker__InvalidAddress.selector);
    govStaker.stake(_amount, _delegatee, address(0));
  }

  function testFuzz_SetsScaledEarningPowerWhenCalculatorScalesStakeAmount(
    address _depositor,
    uint256 _stakeAmount,
    uint256 _multiplierBips
  ) public {
    _stakeAmount = _boundToRealisticStake(_stakeAmount);
    _multiplierBips = bound(_multiplierBips, 0, 20_000);

    earningPowerCalculator.__setMultiplierBips(_multiplierBips);

    (, GovernanceStaker.DepositIdentifier _depositId) =
      _boundMintAndStake(_depositor, _stakeAmount, _depositor);

    (,, uint96 _actualEarningPower,,,,) = govStaker.deposits(_depositId);
    uint256 _expectedEarningPower = (_stakeAmount * _multiplierBips) / 10_000;
    assertEq(_actualEarningPower, _expectedEarningPower);
  }

  function testFuzz_SetsFixedEarningPowerWhenCalculatorReturnsConstantAmount(
    address _depositor,
    uint256 _stakeAmount,
    uint256 _fixedEarningPower
  ) public {
    _stakeAmount = _boundToRealisticStake(_stakeAmount);
    _fixedEarningPower = _boundToRealisticStake(_fixedEarningPower);

    earningPowerCalculator.__setFixedReturn(_fixedEarningPower);

    (, GovernanceStaker.DepositIdentifier _depositId) =
      _boundMintAndStake(_depositor, _stakeAmount, _depositor);

    (,, uint96 _actualEarningPower,,,,) = govStaker.deposits(_depositId);
    assertEq(_actualEarningPower, _fixedEarningPower);
  }
}

contract PermitAndStake is GovernanceStakerTest {
  using stdStorage for StdStorage;

  function testFuzz_PerformsTheApprovalByCallingPermitThenPerformsStake(
    uint256 _depositorPrivateKey,
    uint256 _depositAmount,
    address _delegatee,
    address _claimer,
    uint256 _deadline,
    uint256 _currentNonce
  ) public {
    vm.assume(_delegatee != address(0) && _claimer != address(0));
    _deadline = bound(_deadline, block.timestamp, type(uint256).max);
    _depositorPrivateKey = bound(_depositorPrivateKey, 1, 100e18);
    address _depositor = vm.addr(_depositorPrivateKey);
    _depositAmount = _boundMintAmount(_depositAmount);
    _mintGovToken(_depositor, _depositAmount);

    stdstore.target(address(govToken)).sig("nonces(address)").with_key(_depositor).checked_write(
      _currentNonce
    );

    bytes32 _message = keccak256(
      abi.encode(
        PERMIT_TYPEHASH,
        _depositor,
        address(govStaker),
        _depositAmount,
        govToken.nonces(_depositor),
        _deadline
      )
    );

    bytes32 _messageHash =
      keccak256(abi.encodePacked("\x19\x01", govToken.DOMAIN_SEPARATOR(), _message));
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_depositorPrivateKey, _messageHash);

    vm.prank(_depositor);
    GovernanceStaker.DepositIdentifier _depositId =
      govStaker.permitAndStake(_depositAmount, _delegatee, _claimer, _deadline, _v, _r, _s);
    GovernanceStaker.Deposit memory _deposit = _fetchDeposit(_depositId);

    assertEq(_deposit.balance, _depositAmount);
    assertEq(_deposit.owner, _depositor);
    assertEq(_deposit.delegatee, _delegatee);
    assertEq(_deposit.claimer, _claimer);
  }

  function testFuzz_SuccessfullyStakeWhenApprovalExistsAndPermitSignatureIsInvalid(
    uint256 _depositorPrivateKey,
    uint256 _depositAmount,
    uint256 _approvalAmount,
    address _delegatee,
    address _claimer
  ) public {
    vm.assume(_delegatee != address(0) && _claimer != address(0));
    _depositorPrivateKey = bound(_depositorPrivateKey, 1, 100e18);
    address _depositor = vm.addr(_depositorPrivateKey);
    _depositAmount = _boundMintAmount(_depositAmount);
    _approvalAmount = bound(_approvalAmount, _depositAmount, type(uint96).max);
    _mintGovToken(_depositor, _depositAmount);
    vm.startPrank(_depositor);
    govToken.approve(address(govStaker), _approvalAmount);
    vm.stopPrank();

    bytes32 _message = keccak256(
      abi.encode(
        PERMIT_TYPEHASH,
        _depositor,
        address(govStaker),
        _depositAmount,
        1, // intentionally wrong nonce
        block.timestamp
      )
    );

    bytes32 _messageHash =
      keccak256(abi.encodePacked("\x19\x01", govToken.DOMAIN_SEPARATOR(), _message));
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_depositorPrivateKey, _messageHash);

    vm.prank(_depositor);
    govStaker.permitAndStake(_depositAmount, _delegatee, _claimer, block.timestamp, _v, _r, _s);
    assertEq(govStaker.depositorTotalStaked(_depositor), _depositAmount);
    assertEq(govStaker.depositorTotalEarningPower(_depositor), _depositAmount);
  }

  function testFuzz_RevertIf_ThePermitSignatureIsInvalidAndTheApprovalIsInsufficient(
    address _notDepositor,
    uint256 _depositorPrivateKey,
    uint256 _depositAmount,
    uint256 _approvalAmount,
    address _delegatee,
    address _claimer,
    uint256 _deadline
  ) public {
    vm.assume(_delegatee != address(0) && _claimer != address(0));
    _deadline = bound(_deadline, block.timestamp, type(uint256).max);
    _depositorPrivateKey = bound(_depositorPrivateKey, 1, 100e18);
    address _depositor = vm.addr(_depositorPrivateKey);
    vm.assume(_notDepositor != _depositor);
    _depositAmount = _boundMintAmount(_depositAmount) + 1;
    _approvalAmount = bound(_approvalAmount, 0, _depositAmount - 1);
    _mintGovToken(_depositor, _depositAmount);
    vm.startPrank(_depositor);
    govToken.approve(address(govStaker), _approvalAmount);
    vm.stopPrank();

    bytes32 _message = keccak256(
      abi.encode(
        PERMIT_TYPEHASH,
        _notDepositor,
        address(govStaker),
        _depositAmount,
        govToken.nonces(_depositor),
        _deadline
      )
    );

    bytes32 _messageHash =
      keccak256(abi.encodePacked("\x19\x01", govToken.DOMAIN_SEPARATOR(), _message));
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_depositorPrivateKey, _messageHash);

    vm.prank(_depositor);
    vm.expectRevert(
      abi.encodeWithSelector(
        IERC20Errors.ERC20InsufficientAllowance.selector,
        address(govStaker),
        _approvalAmount,
        _depositAmount
      )
    );
    govStaker.permitAndStake(_depositAmount, _delegatee, _claimer, _deadline, _v, _r, _s);
  }

  function testFuzz_SetsScaledEarningPowerWhenStaking(
    uint256 _depositorPrivateKey,
    uint256 _depositAmount,
    address _delegatee,
    address _claimer,
    uint256 _deadline,
    uint256 _currentNonce,
    uint256 _multiplierBips
  ) public {
    vm.assume(_delegatee != address(0) && _claimer != address(0));
    _deadline = bound(_deadline, block.timestamp, type(uint256).max);
    _depositorPrivateKey = bound(_depositorPrivateKey, 1, 100e18);
    address _depositor = vm.addr(_depositorPrivateKey);
    _depositAmount = _boundMintAmount(_depositAmount);
    _multiplierBips = bound(_multiplierBips, 0, 20_000); // 0% to 200%

    earningPowerCalculator.__setMultiplierBips(_multiplierBips);

    _mintGovToken(_depositor, _depositAmount);
    stdstore.target(address(govToken)).sig("nonces(address)").with_key(_depositor).checked_write(
      _currentNonce
    );

    bytes32 _message = keccak256(
      abi.encode(
        PERMIT_TYPEHASH,
        _depositor,
        address(govStaker),
        _depositAmount,
        govToken.nonces(_depositor),
        _deadline
      )
    );

    bytes32 _messageHash =
      keccak256(abi.encodePacked("\x19\x01", govToken.DOMAIN_SEPARATOR(), _message));
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_depositorPrivateKey, _messageHash);

    vm.prank(_depositor);
    GovernanceStaker.DepositIdentifier _depositId =
      govStaker.permitAndStake(_depositAmount, _delegatee, _claimer, _deadline, _v, _r, _s);

    uint256 _expectedEarningPower = (_depositAmount * _multiplierBips) / 10_000;
    GovernanceStaker.Deposit memory _deposit = _fetchDeposit(_depositId);

    assertEq(_deposit.earningPower, _expectedEarningPower);
    assertEq(govStaker.totalEarningPower(), _expectedEarningPower);
    assertEq(govStaker.depositorTotalEarningPower(_depositor), _expectedEarningPower);
  }

  function testFuzz_SetsFixedEarningPowerWhenStaking(
    uint256 _depositorPrivateKey,
    uint256 _depositAmount,
    address _delegatee,
    address _claimer,
    uint256 _deadline,
    uint256 _currentNonce,
    uint256 _fixedEarningPower
  ) public {
    vm.assume(_delegatee != address(0) && _claimer != address(0));
    _deadline = bound(_deadline, block.timestamp, type(uint256).max);
    _depositorPrivateKey = bound(_depositorPrivateKey, 1, 100e18);
    address _depositor = vm.addr(_depositorPrivateKey);
    _depositAmount = _boundMintAmount(_depositAmount);
    _fixedEarningPower = _boundToRealisticStake(_fixedEarningPower);

    earningPowerCalculator.__setFixedReturn(_fixedEarningPower);

    _mintGovToken(_depositor, _depositAmount);
    stdstore.target(address(govToken)).sig("nonces(address)").with_key(_depositor).checked_write(
      _currentNonce
    );

    bytes32 _message = keccak256(
      abi.encode(
        PERMIT_TYPEHASH,
        _depositor,
        address(govStaker),
        _depositAmount,
        govToken.nonces(_depositor),
        _deadline
      )
    );

    bytes32 _messageHash =
      keccak256(abi.encodePacked("\x19\x01", govToken.DOMAIN_SEPARATOR(), _message));
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_depositorPrivateKey, _messageHash);

    vm.prank(_depositor);
    GovernanceStaker.DepositIdentifier _depositId =
      govStaker.permitAndStake(_depositAmount, _delegatee, _claimer, _deadline, _v, _r, _s);

    GovernanceStaker.Deposit memory _deposit = _fetchDeposit(_depositId);

    assertEq(_deposit.earningPower, _fixedEarningPower);
    assertEq(govStaker.totalEarningPower(), _fixedEarningPower);
    assertEq(govStaker.depositorTotalEarningPower(_depositor), _fixedEarningPower);
  }
}

contract StakeMore is GovernanceStakerTest {
  function testFuzz_TransfersStakeToTheExistingSurrogate(
    address _depositor,
    uint256 _depositAmount,
    uint256 _addAmount,
    address _delegatee,
    address _claimer
  ) public {
    GovernanceStaker.DepositIdentifier _depositId;
    (_depositAmount, _depositId) =
      _boundMintAndStake(_depositor, _depositAmount, _delegatee, _claimer);
    GovernanceStaker.Deposit memory _deposit = _fetchDeposit(_depositId);
    DelegationSurrogate _surrogate = govStaker.surrogates(_deposit.delegatee);

    _addAmount = _boundToRealisticStake(_addAmount);
    _mintGovToken(_depositor, _addAmount);

    vm.startPrank(_depositor);
    govToken.approve(address(govStaker), _addAmount);
    govStaker.stakeMore(_depositId, _addAmount);
    vm.stopPrank();

    assertEq(govToken.balanceOf(address(_surrogate)), _depositAmount + _addAmount);
  }

  function testFuzz_AddsToTheTotalStaked(
    address _depositor,
    uint256 _depositAmount,
    uint256 _addAmount,
    address _delegatee,
    address _claimer
  ) public {
    GovernanceStaker.DepositIdentifier _depositId;
    (_depositAmount, _depositId) =
      _boundMintAndStake(_depositor, _depositAmount, _delegatee, _claimer);

    _addAmount = _boundToRealisticStake(_addAmount);
    _mintGovToken(_depositor, _addAmount);

    vm.startPrank(_depositor);
    govToken.approve(address(govStaker), _addAmount);
    govStaker.stakeMore(_depositId, _addAmount);
    vm.stopPrank();

    assertEq(govStaker.totalStaked(), _depositAmount + _addAmount);
  }

  function testFuzz_AddsToDepositorsTotalStaked(
    address _depositor,
    uint256 _depositAmount,
    uint256 _addAmount,
    address _delegatee,
    address _claimer
  ) public {
    GovernanceStaker.DepositIdentifier _depositId;
    (_depositAmount, _depositId) =
      _boundMintAndStake(_depositor, _depositAmount, _delegatee, _claimer);

    _addAmount = _boundToRealisticStake(_addAmount);
    _mintGovToken(_depositor, _addAmount);

    vm.startPrank(_depositor);
    govToken.approve(address(govStaker), _addAmount);
    govStaker.stakeMore(_depositId, _addAmount);
    vm.stopPrank();

    assertEq(govStaker.depositorTotalStaked(_depositor), _depositAmount + _addAmount);
  }

  function testFuzz_AddsToDepositorsTotalEarningPower(
    address _depositor,
    uint256 _depositAmount,
    uint256 _addAmount,
    address _delegatee,
    address _claimer
  ) public {
    GovernanceStaker.DepositIdentifier _depositId;
    (_depositAmount, _depositId) =
      _boundMintAndStake(_depositor, _depositAmount, _delegatee, _claimer);

    _addAmount = _boundToRealisticStake(_addAmount);
    _mintGovToken(_depositor, _addAmount);

    vm.startPrank(_depositor);
    govToken.approve(address(govStaker), _addAmount);
    govStaker.stakeMore(_depositId, _addAmount);
    vm.stopPrank();

    assertEq(govStaker.depositorTotalEarningPower(_depositor), _depositAmount + _addAmount);
  }

  function testFuzz_AddsToTheDepositBalance(
    address _depositor,
    uint256 _depositAmount,
    uint256 _addAmount,
    address _delegatee,
    address _claimer
  ) public {
    GovernanceStaker.DepositIdentifier _depositId;
    (_depositAmount, _depositId) =
      _boundMintAndStake(_depositor, _depositAmount, _delegatee, _claimer);

    _addAmount = _boundToRealisticStake(_addAmount);
    _mintGovToken(_depositor, _addAmount);

    vm.startPrank(_depositor);
    govToken.approve(address(govStaker), _addAmount);
    govStaker.stakeMore(_depositId, _addAmount);
    vm.stopPrank();

    GovernanceStaker.Deposit memory _deposit = _fetchDeposit(_depositId);

    assertEq(_deposit.balance, _depositAmount + _addAmount);
  }

  function testFuzz_EmitsAnEventWhenStakingMore(
    address _depositor,
    uint256 _depositAmount,
    uint256 _addAmount,
    address _delegatee,
    address _claimer
  ) public {
    uint256 _totalAdditionalStake;
    GovernanceStaker.DepositIdentifier _depositId;
    (_depositAmount, _depositId) =
      _boundMintAndStake(_depositor, _depositAmount, _delegatee, _claimer);
    // Second stake
    _boundMintAndStake(_depositor, _depositAmount, _delegatee, _claimer);

    _addAmount = _boundToRealisticStake(_addAmount);
    _totalAdditionalStake = _addAmount * 2;
    _mintGovToken(_depositor, _totalAdditionalStake);

    vm.startPrank(_depositor);
    govToken.approve(address(govStaker), _addAmount * 2);

    govStaker.stakeMore(_depositId, _addAmount);

    vm.expectEmit();
    emit GovernanceStaker.StakeDeposited(
      _depositor, _depositId, _addAmount, _depositAmount + _totalAdditionalStake
    );

    govStaker.stakeMore(_depositId, _addAmount);
    vm.stopPrank();
  }

  function testFuzz_RevertIf_TheCallerIsNotTheDepositor(
    address _depositor,
    address _notDepositor,
    uint256 _depositAmount,
    uint256 _addAmount,
    address _delegatee,
    address _claimer
  ) public {
    vm.assume(_notDepositor != _depositor);

    GovernanceStaker.DepositIdentifier _depositId;
    (_depositAmount, _depositId) =
      _boundMintAndStake(_depositor, _depositAmount, _delegatee, _claimer);

    _addAmount = _boundToRealisticStake(_addAmount);
    _mintGovToken(_depositor, _addAmount);

    vm.prank(_depositor);
    govToken.approve(address(govStaker), _addAmount);

    vm.prank(_notDepositor);
    vm.expectRevert(
      abi.encodeWithSelector(
        GovernanceStaker.GovernanceStaker__Unauthorized.selector,
        bytes32("not owner"),
        _notDepositor
      )
    );
    govStaker.stakeMore(_depositId, _addAmount);
  }

  function testFuzz_RevertIf_TheDepositIdentifierIsInvalid(
    address _depositor,
    GovernanceStaker.DepositIdentifier _depositId,
    uint256 _addAmount
  ) public {
    vm.assume(_depositor != address(0));
    _addAmount = _boundToRealisticStake(_addAmount);

    // Since no deposits have been made yet, all DepositIdentifiers are invalid, and any call to
    // add stake to one should revert. We rely on the default owner of any uninitialized deposit
    // being address zero, which means the address attempting to alter it won't be able to.
    vm.prank(_depositor);
    vm.expectRevert(
      abi.encodeWithSelector(
        GovernanceStaker.GovernanceStaker__Unauthorized.selector, bytes32("not owner"), _depositor
      )
    );
    govStaker.stakeMore(_depositId, _addAmount);
  }

  function testFuzz_SetsCorrectEarningPowerWhenCalculatorScalesStakeAmount(
    address _depositor,
    uint256 _depositAmount,
    uint256 _addAmount,
    address _delegatee,
    uint256 _multiplierBips
  ) public {
    _multiplierBips = bound(_multiplierBips, 0, 20_000);
    earningPowerCalculator.__setMultiplierBips(_multiplierBips);

    GovernanceStaker.DepositIdentifier _depositId;
    (_depositAmount, _depositId) = _boundMintAndStake(_depositor, _depositAmount, _delegatee);

    _addAmount = _boundToRealisticStake(_addAmount);
    _mintGovToken(_depositor, _addAmount);
    vm.startPrank(_depositor);
    govToken.approve(address(govStaker), _addAmount);
    govStaker.stakeMore(_depositId, _addAmount);
    vm.stopPrank();

    (,, uint96 _actualEarningPower,,,,) = govStaker.deposits(_depositId);
    uint256 _expectedEarningPower = ((_depositAmount + _addAmount) * _multiplierBips) / 10_000;
    assertEq(_actualEarningPower, _expectedEarningPower);
  }

  function testFuzz_SetsFixedEarningPowerWhenCalculatorReturnsConstantAmount(
    address _depositor,
    uint256 _depositAmount,
    uint256 _addAmount,
    address _delegatee,
    uint256 _fixedEarningPower
  ) public {
    _fixedEarningPower = _boundToRealisticStake(_fixedEarningPower);
    earningPowerCalculator.__setFixedReturn(_fixedEarningPower);

    GovernanceStaker.DepositIdentifier _depositId;
    (_depositAmount, _depositId) = _boundMintAndStake(_depositor, _depositAmount, _delegatee);

    _addAmount = _boundToRealisticStake(_addAmount);
    _mintGovToken(_depositor, _addAmount);
    vm.startPrank(_depositor);
    govToken.approve(address(govStaker), _addAmount);
    govStaker.stakeMore(_depositId, _addAmount);
    vm.stopPrank();

    (,, uint96 _actualEarningPower,,,,) = govStaker.deposits(_depositId);
    assertEq(_actualEarningPower, _fixedEarningPower);
  }

  function testFuzz_UpdatesGlobalTotalEarningPowerWhenStakingMore(
    address _depositor,
    uint256 _depositAmount,
    uint256 _addAmount,
    address _delegatee,
    uint256 _multiplierBips
  ) public {
    _multiplierBips = bound(_multiplierBips, 0, 20_000);
    earningPowerCalculator.__setMultiplierBips(_multiplierBips);

    GovernanceStaker.DepositIdentifier _depositId;
    (_depositAmount, _depositId) = _boundMintAndStake(_depositor, _depositAmount, _delegatee);

    _addAmount = _boundToRealisticStake(_addAmount);
    _mintGovToken(_depositor, _addAmount);
    vm.startPrank(_depositor);
    govToken.approve(address(govStaker), _addAmount);
    govStaker.stakeMore(_depositId, _addAmount);
    vm.stopPrank();

    uint256 _expectedEarningPower = ((_depositAmount + _addAmount) * _multiplierBips) / 10_000;
    assertEq(govStaker.totalEarningPower(), _expectedEarningPower);
  }
}

contract PermitAndStakeMore is GovernanceStakerTest {
  using stdStorage for StdStorage;

  function testFuzz_PerformsTheApprovalByCallingPermitThenPerformsStakeMore(
    uint256 _depositorPrivateKey,
    uint256 _initialDepositAmount,
    uint256 _stakeMoreAmount,
    address _delegatee,
    address _claimer,
    uint256 _currentNonce,
    uint256 _deadline
  ) public {
    vm.assume(_delegatee != address(0) && _claimer != address(0));
    _depositorPrivateKey = bound(_depositorPrivateKey, 1, 100e18);
    address _depositor = vm.addr(_depositorPrivateKey);
    _deadline = bound(_deadline, block.timestamp, type(uint256).max);

    GovernanceStaker.DepositIdentifier _depositId;
    (_initialDepositAmount, _depositId) =
      _boundMintAndStake(_depositor, _initialDepositAmount, _delegatee, _claimer);

    _stakeMoreAmount = _boundToRealisticStake(_stakeMoreAmount);
    _mintGovToken(_depositor, _stakeMoreAmount);

    stdstore.target(address(govToken)).sig("nonces(address)").with_key(_depositor).checked_write(
      _currentNonce
    );

    // Separate scope to avoid stack to deep errors
    {
      bytes32 _message = keccak256(
        abi.encode(
          PERMIT_TYPEHASH,
          _depositor,
          address(govStaker),
          _stakeMoreAmount,
          govToken.nonces(_depositor),
          _deadline
        )
      );

      bytes32 _messageHash =
        keccak256(abi.encodePacked("\x19\x01", govToken.DOMAIN_SEPARATOR(), _message));
      (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_depositorPrivateKey, _messageHash);

      vm.prank(_depositor);
      govStaker.permitAndStakeMore(_depositId, _stakeMoreAmount, _deadline, _v, _r, _s);
    }

    GovernanceStaker.Deposit memory _deposit = _fetchDeposit(_depositId);

    assertEq(_deposit.balance, _initialDepositAmount + _stakeMoreAmount);
    assertEq(_deposit.owner, _depositor);
    assertEq(_deposit.delegatee, _delegatee);
    assertEq(_deposit.claimer, _claimer);
  }

  function testFuzz_SuccessfullyStakeMoreWhenApprovalExistsAndPermitSignatureIsInvalid(
    uint256 _initialDepositAmount,
    uint256 _stakeMoreAmount,
    uint256 _approvalAmount,
    address _delegatee,
    address _claimer
  ) public {
    vm.assume(_delegatee != address(0) && _claimer != address(0));
    (address _depositor, uint256 _depositorPrivateKey) = makeAddrAndKey("depositor");
    GovernanceStaker.DepositIdentifier _depositId;
    (_initialDepositAmount, _depositId) =
      _boundMintAndStake(_depositor, _initialDepositAmount, _delegatee, _claimer);
    _stakeMoreAmount = bound(_stakeMoreAmount, 0, type(uint96).max - _initialDepositAmount);
    _approvalAmount = bound(_approvalAmount, _stakeMoreAmount, type(uint96).max);
    _mintGovToken(_depositor, _stakeMoreAmount);
    vm.prank(_depositor);
    govToken.approve(address(govStaker), _approvalAmount);

    bytes32 _message = keccak256(
      abi.encode(
        PERMIT_TYPEHASH,
        _depositor,
        address(govStaker),
        _stakeMoreAmount,
        1, // intentionally incorrect nonce, which should be 0
        block.timestamp + 10_000
      )
    );

    bytes32 _messageHash =
      keccak256(abi.encodePacked("\x19\x01", govToken.DOMAIN_SEPARATOR(), _message));

    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_depositorPrivateKey, _messageHash);

    vm.prank(_depositor);
    govStaker.permitAndStakeMore(_depositId, _stakeMoreAmount, block.timestamp, _v, _r, _s);
    assertEq(govStaker.depositorTotalStaked(_depositor), _initialDepositAmount + _stakeMoreAmount);
    assertEq(
      govStaker.depositorTotalEarningPower(_depositor), _initialDepositAmount + _stakeMoreAmount
    );
  }

  function testFuzz_RevertIf_CallerIsNotTheDepositOwner(
    address _depositor,
    uint256 _notDepositorPrivateKey,
    uint256 _initialDepositAmount,
    uint256 _stakeMoreAmount,
    address _delegatee,
    address _claimer,
    uint256 _deadline
  ) public {
    vm.assume(_delegatee != address(0) && _claimer != address(0));
    _notDepositorPrivateKey = bound(_notDepositorPrivateKey, 1, 100e18);
    address _notDepositor = vm.addr(_notDepositorPrivateKey);
    vm.assume(_depositor != _notDepositor);
    _deadline = bound(_deadline, block.timestamp, type(uint256).max);

    GovernanceStaker.DepositIdentifier _depositId;
    (_initialDepositAmount, _depositId) =
      _boundMintAndStake(_depositor, _initialDepositAmount, _delegatee, _claimer);

    _stakeMoreAmount = _boundToRealisticStake(_stakeMoreAmount);
    _mintGovToken(_depositor, _stakeMoreAmount);

    // Separate scope to avoid stack to deep errors
    {
      bytes32 _message = keccak256(
        abi.encode(
          PERMIT_TYPEHASH,
          _notDepositor,
          address(govStaker),
          _stakeMoreAmount,
          govToken.nonces(_depositor),
          _deadline
        )
      );

      bytes32 _messageHash =
        keccak256(abi.encodePacked("\x19\x01", govToken.DOMAIN_SEPARATOR(), _message));
      (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_notDepositorPrivateKey, _messageHash);

      vm.prank(_notDepositor);
      vm.expectRevert(
        abi.encodeWithSelector(
          GovernanceStaker.GovernanceStaker__Unauthorized.selector,
          bytes32("not owner"),
          _notDepositor
        )
      );
      govStaker.permitAndStakeMore(_depositId, _stakeMoreAmount, _deadline, _v, _r, _s);
    }
  }

  function testFuzz_RevertIf_ThePermitSignatureIsInvalidAndTheApprovalIsInsufficient(
    uint256 _initialDepositAmount,
    address _delegatee,
    address _claimer
  ) public {
    vm.assume(_delegatee != address(0) && _claimer != address(0));

    // We can't fuzz the these values because we need to pre-compute the invalid
    // recovered signer so we can expect it in the revert error message thrown
    (address _depositor, uint256 _depositorPrivateKey) = makeAddrAndKey("depositor");
    uint256 _stakeMoreAmount = 1578e18;
    uint256 _deadline = 1e18 days;
    uint256 _wrongNonce = 1;
    uint256 _approvalAmount = _stakeMoreAmount - 1;

    GovernanceStaker.DepositIdentifier _depositId;
    (_initialDepositAmount, _depositId) =
      _boundMintAndStake(_depositor, _initialDepositAmount, _delegatee, _claimer);
    _mintGovToken(_depositor, _stakeMoreAmount);
    vm.prank(_depositor);
    govToken.approve(address(govStaker), _approvalAmount);

    bytes32 _message = keccak256(
      abi.encode(
        PERMIT_TYPEHASH,
        _depositor,
        address(govStaker),
        _stakeMoreAmount,
        _wrongNonce, // intentionally incorrect nonce, which should be 0
        _deadline
      )
    );

    bytes32 _messageHash =
      keccak256(abi.encodePacked("\x19\x01", govToken.DOMAIN_SEPARATOR(), _message));

    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_depositorPrivateKey, _messageHash);

    vm.prank(_depositor);
    vm.expectRevert(
      abi.encodeWithSelector(
        IERC20Errors.ERC20InsufficientAllowance.selector,
        address(govStaker),
        _approvalAmount,
        _stakeMoreAmount
      )
    );
    govStaker.permitAndStakeMore(_depositId, _stakeMoreAmount, _deadline, _v, _r, _s);
  }

  function testFuzz_SetsScaledEarningPowerWhenStakingMore(
    uint256 _depositorPrivateKey,
    uint256 _depositAmount,
    uint256 _addAmount,
    address _delegatee,
    address _claimer,
    uint256 _multiplierBips
  ) public {
    vm.assume(_delegatee != address(0) && _claimer != address(0));
    _depositorPrivateKey = bound(_depositorPrivateKey, 1, 100e18);
    address _depositor = vm.addr(_depositorPrivateKey);

    GovernanceStaker.DepositIdentifier _depositId;
    (_depositAmount, _depositId) =
      _boundMintAndStake(_depositor, _depositAmount, _delegatee, _claimer);

    _addAmount = _boundToRealisticStake(_addAmount);
    _multiplierBips = bound(_multiplierBips, 0, 20_000);
    earningPowerCalculator.__setMultiplierBips(_multiplierBips);

    _executePermitAndStakeMore(_depositor, _depositorPrivateKey, _depositId, _addAmount);

    uint256 _totalStaked = _depositAmount + _addAmount;
    uint256 _expectedEarningPower = (_totalStaked * _multiplierBips) / 10_000;
    GovernanceStaker.Deposit memory _deposit = _fetchDeposit(_depositId);

    assertEq(_deposit.earningPower, _expectedEarningPower);
    assertEq(govStaker.totalEarningPower(), _expectedEarningPower);
    assertEq(govStaker.depositorTotalEarningPower(_depositor), _expectedEarningPower);
  }

  function testFuzz_SetsFixedEarningPowerWhenStakingMore(
    uint256 _depositorPrivateKey,
    uint256 _depositAmount,
    uint256 _addAmount,
    address _delegatee,
    address _claimer,
    uint256 _fixedEarningPower
  ) public {
    vm.assume(_delegatee != address(0) && _claimer != address(0));
    _depositorPrivateKey = bound(_depositorPrivateKey, 1, 100e18);
    address _depositor = vm.addr(_depositorPrivateKey);

    GovernanceStaker.DepositIdentifier _depositId;
    (_depositAmount, _depositId) =
      _boundMintAndStake(_depositor, _depositAmount, _delegatee, _claimer);

    _addAmount = _boundToRealisticStake(_addAmount);
    _fixedEarningPower = _boundToRealisticStake(_fixedEarningPower);
    earningPowerCalculator.__setFixedReturn(_fixedEarningPower);

    _executePermitAndStakeMore(_depositor, _depositorPrivateKey, _depositId, _addAmount);

    GovernanceStaker.Deposit memory _deposit = _fetchDeposit(_depositId);

    assertEq(_deposit.earningPower, _fixedEarningPower);
    assertEq(govStaker.totalEarningPower(), _fixedEarningPower);
    assertEq(govStaker.depositorTotalEarningPower(_depositor), _fixedEarningPower);
  }

  // Helper function to handle permit and stakeMore execution without stack too deep errors
  function _executePermitAndStakeMore(
    address _depositor,
    uint256 _depositorPrivateKey,
    GovernanceStaker.DepositIdentifier _depositId,
    uint256 _addAmount
  ) internal {
    _mintGovToken(_depositor, _addAmount);

    uint256 _deadline = block.timestamp + 1 days;
    uint256 _currentNonce = 0;
    stdstore.target(address(govToken)).sig("nonces(address)").with_key(_depositor).checked_write(
      _currentNonce
    );

    bytes32 _message = keccak256(
      abi.encode(
        PERMIT_TYPEHASH, _depositor, address(govStaker), _addAmount, _currentNonce, _deadline
      )
    );

    bytes32 _messageHash =
      keccak256(abi.encodePacked("\x19\x01", govToken.DOMAIN_SEPARATOR(), _message));
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_depositorPrivateKey, _messageHash);

    vm.prank(_depositor);
    govStaker.permitAndStakeMore(_depositId, _addAmount, _deadline, _v, _r, _s);
  }
}

contract AlterDelegatee is GovernanceStakerTest {
  function testFuzz_AllowsStakerToUpdateTheirDelegatee(
    address _depositor,
    uint256 _depositAmount,
    address _firstDelegatee,
    address _claimer,
    address _newDelegatee
  ) public {
    vm.assume(_newDelegatee != address(0) && _newDelegatee != _firstDelegatee);

    GovernanceStaker.DepositIdentifier _depositId;
    (_depositAmount, _depositId) =
      _boundMintAndStake(_depositor, _depositAmount, _firstDelegatee, _claimer);
    address _firstSurrogate = address(govStaker.surrogates(_firstDelegatee));

    vm.prank(_depositor);
    govStaker.alterDelegatee(_depositId, _newDelegatee);

    GovernanceStaker.Deposit memory _deposit = _fetchDeposit(_depositId);
    address _newSurrogate = address(govStaker.surrogates(_deposit.delegatee));

    assertEq(_deposit.delegatee, _newDelegatee);
    assertEq(govToken.balanceOf(_newSurrogate), _depositAmount);
    assertEq(govToken.balanceOf(_firstSurrogate), 0);
  }

  function testFuzz_AllowsStakerToReiterateTheirDelegatee(
    address _depositor,
    uint256 _depositAmount,
    address _delegatee,
    address _claimer
  ) public {
    GovernanceStaker.DepositIdentifier _depositId;
    (_depositAmount, _depositId) =
      _boundMintAndStake(_depositor, _depositAmount, _delegatee, _claimer);
    address _beforeSurrogate = address(govStaker.surrogates(_delegatee));

    // We are calling alterDelegatee with the address that is already the delegatee to ensure that
    // doing so does not break anything other than wasting the user's gas
    vm.prank(_depositor);
    govStaker.alterDelegatee(_depositId, _delegatee);

    GovernanceStaker.Deposit memory _deposit = _fetchDeposit(_depositId);
    address _afterSurrogate = address(govStaker.surrogates(_deposit.delegatee));

    assertEq(_deposit.delegatee, _delegatee);
    assertEq(_beforeSurrogate, _afterSurrogate);
    assertEq(govToken.balanceOf(_afterSurrogate), _depositAmount);
  }

  function testFuzz_EmitsAnEventWhenADelegateeIsChanged(
    address _depositor,
    uint256 _depositAmount,
    address _firstDelegatee,
    address _claimer,
    address _newDelegatee
  ) public {
    vm.assume(_newDelegatee != address(0) && _newDelegatee != _firstDelegatee);

    GovernanceStaker.DepositIdentifier _depositId;
    (_depositAmount, _depositId) =
      _boundMintAndStake(_depositor, _depositAmount, _firstDelegatee, _claimer);

    vm.expectEmit();
    emit GovernanceStaker.DelegateeAltered(_depositId, _firstDelegatee, _newDelegatee);

    vm.prank(_depositor);
    govStaker.alterDelegatee(_depositId, _newDelegatee);
  }

  function testFuzz_UpdatesDepositsEarningPower(
    address _depositor,
    uint256 _depositAmount,
    address _firstDelegatee,
    address _claimer,
    address _newDelegatee,
    uint96 _newEarningPower
  ) public {
    vm.assume(_newDelegatee != address(0) && _newDelegatee != _firstDelegatee);

    GovernanceStaker.DepositIdentifier _depositId;
    (_depositAmount, _depositId) =
      _boundMintAndStake(_depositor, _depositAmount, _firstDelegatee, _claimer);

    earningPowerCalculator.__setEarningPowerAndIsQualifiedForDelegatee(
      _newDelegatee, _newEarningPower, true
    );

    vm.prank(_depositor);
    govStaker.alterDelegatee(_depositId, _newDelegatee);

    GovernanceStaker.Deposit memory _deposit = _fetchDeposit(_depositId);

    assertEq(_deposit.earningPower, _newEarningPower);
  }

  function testFuzz_UpdatesGlobalTotalEarningPower(
    address _depositor,
    uint256 _depositAmount,
    address _firstDelegatee,
    address _claimer,
    address _newDelegatee,
    uint96 _newEarningPower
  ) public {
    vm.assume(_newDelegatee != address(0) && _newDelegatee != _firstDelegatee);

    GovernanceStaker.DepositIdentifier _depositId;
    (_depositAmount, _depositId) =
      _boundMintAndStake(_depositor, _depositAmount, _firstDelegatee, _claimer);

    earningPowerCalculator.__setEarningPowerAndIsQualifiedForDelegatee(
      _newDelegatee, _newEarningPower, true
    );

    vm.prank(_depositor);
    govStaker.alterDelegatee(_depositId, _newDelegatee);

    assertEq(govStaker.totalEarningPower(), _newEarningPower);
  }

  function testFuzz_UpdatesDepositorsTotalEarningPower(
    address _depositor,
    uint256 _depositAmount,
    address _firstDelegatee,
    address _claimer,
    address _newDelegatee,
    uint96 _newEarningPower
  ) public {
    vm.assume(_newDelegatee != address(0) && _newDelegatee != _firstDelegatee);

    GovernanceStaker.DepositIdentifier _depositId;
    (_depositAmount, _depositId) =
      _boundMintAndStake(_depositor, _depositAmount, _firstDelegatee, _claimer);

    earningPowerCalculator.__setEarningPowerAndIsQualifiedForDelegatee(
      _newDelegatee, _newEarningPower, true
    );

    vm.prank(_depositor);
    govStaker.alterDelegatee(_depositId, _newDelegatee);

    assertEq(govStaker.depositorTotalEarningPower(_depositor), _newEarningPower);
  }

  function testFuzz_RevertIf_TheCallerIsNotTheDepositor(
    address _depositor,
    address _notDepositor,
    uint256 _depositAmount,
    address _firstDelegatee,
    address _claimer,
    address _newDelegatee
  ) public {
    vm.assume(
      _depositor != _notDepositor && _newDelegatee != address(0) && _newDelegatee != _firstDelegatee
    );

    GovernanceStaker.DepositIdentifier _depositId;
    (_depositAmount, _depositId) =
      _boundMintAndStake(_depositor, _depositAmount, _firstDelegatee, _claimer);

    vm.prank(_notDepositor);
    vm.expectRevert(
      abi.encodeWithSelector(
        GovernanceStaker.GovernanceStaker__Unauthorized.selector,
        bytes32("not owner"),
        _notDepositor
      )
    );
    govStaker.alterDelegatee(_depositId, _newDelegatee);
  }

  function testFuzz_RevertIf_TheDepositIdentifierIsInvalid(
    address _depositor,
    GovernanceStaker.DepositIdentifier _depositId,
    address _newDelegatee
  ) public {
    vm.assume(_depositor != address(0) && _newDelegatee != address(0));

    // Since no deposits have been made yet, all DepositIdentifiers are invalid, and any call to
    // alter one should revert. We rely on the default owner of any uninitialized deposit being
    // address zero, which means the address attempting to alter it won't be able to.
    vm.prank(_depositor);
    vm.expectRevert(
      abi.encodeWithSelector(
        GovernanceStaker.GovernanceStaker__Unauthorized.selector, bytes32("not owner"), _depositor
      )
    );
    govStaker.alterDelegatee(_depositId, _newDelegatee);
  }

  function testFuzz_RevertIf_DelegateeIsTheZeroAddress(
    address _depositor,
    uint256 _depositAmount,
    address _delegatee
  ) public {
    GovernanceStaker.DepositIdentifier _depositId;
    (_depositAmount, _depositId) = _boundMintAndStake(_depositor, _depositAmount, _delegatee);

    vm.prank(_depositor);
    vm.expectRevert(GovernanceStaker.GovernanceStaker__InvalidAddress.selector);
    govStaker.alterDelegatee(_depositId, address(0));
  }

  function testFuzz_SetsScaledEarningPowerWhenCalculatorScalesStakeAmount(
    address _depositor,
    uint256 _depositAmount,
    address _firstDelegatee,
    address _claimer,
    address _newDelegatee,
    uint256 _multiplierBips
  ) public {
    vm.assume(_newDelegatee != address(0) && _newDelegatee != _firstDelegatee);

    _multiplierBips = bound(_multiplierBips, 0, 20_000);
    earningPowerCalculator.__setMultiplierBips(_multiplierBips);

    GovernanceStaker.DepositIdentifier _depositId;
    (_depositAmount, _depositId) =
      _boundMintAndStake(_depositor, _depositAmount, _firstDelegatee, _claimer);

    vm.prank(_depositor);
    govStaker.alterDelegatee(_depositId, _newDelegatee);

    uint256 _expectedEarningPower = (_depositAmount * _multiplierBips) / 10_000;

    GovernanceStaker.Deposit memory _deposit = _fetchDeposit(_depositId);
    assertEq(_deposit.earningPower, _expectedEarningPower);
    assertEq(govStaker.totalEarningPower(), _expectedEarningPower);
    assertEq(govStaker.depositorTotalEarningPower(_depositor), _expectedEarningPower);
  }

  function testFuzz_SetsFixedEarningPowerWhenCalculatorReturnsConstantAmount(
    address _depositor,
    uint256 _depositAmount,
    address _firstDelegatee,
    address _claimer,
    address _newDelegatee,
    uint256 _fixedEarningPower
  ) public {
    vm.assume(_newDelegatee != address(0) && _newDelegatee != _firstDelegatee);

    _fixedEarningPower = _boundToRealisticStake(_fixedEarningPower);
    earningPowerCalculator.__setFixedReturn(_fixedEarningPower);

    GovernanceStaker.DepositIdentifier _depositId;
    (_depositAmount, _depositId) =
      _boundMintAndStake(_depositor, _depositAmount, _firstDelegatee, _claimer);

    vm.prank(_depositor);
    govStaker.alterDelegatee(_depositId, _newDelegatee);

    GovernanceStaker.Deposit memory _deposit = _fetchDeposit(_depositId);
    assertEq(_deposit.earningPower, _fixedEarningPower);
    assertEq(govStaker.totalEarningPower(), _fixedEarningPower);
    assertEq(govStaker.depositorTotalEarningPower(_depositor), _fixedEarningPower);
  }
}

contract AlterClaimer is GovernanceStakerTest {
  function testFuzz_AllowsStakerToUpdateTheirClaimer(
    address _depositor,
    uint256 _depositAmount,
    address _delegatee,
    address _firstClaimer,
    address _newClaimer
  ) public {
    vm.assume(_newClaimer != address(0) && _newClaimer != _firstClaimer);

    GovernanceStaker.DepositIdentifier _depositId;
    (_depositAmount, _depositId) =
      _boundMintAndStake(_depositor, _depositAmount, _delegatee, _firstClaimer);

    vm.prank(_depositor);
    govStaker.alterClaimer(_depositId, _newClaimer);

    GovernanceStaker.Deposit memory _deposit = _fetchDeposit(_depositId);

    assertEq(_deposit.claimer, _newClaimer);
  }

  function testFuzz_AllowsStakerToReiterateTheirClaimer(
    address _depositor,
    uint256 _depositAmount,
    address _delegatee,
    address _claimer
  ) public {
    GovernanceStaker.DepositIdentifier _depositId;
    (_depositAmount, _depositId) =
      _boundMintAndStake(_depositor, _depositAmount, _delegatee, _claimer);

    // We are calling alterClaimer with the address that is already the claimer to ensure
    // that doing so does not break anything other than wasting the user's gas
    vm.prank(_depositor);
    govStaker.alterClaimer(_depositId, _claimer);

    GovernanceStaker.Deposit memory _deposit = _fetchDeposit(_depositId);

    assertEq(_deposit.claimer, _claimer);
  }

  function testFuzz_EmitsAnEventWhenClaimerAltered(
    address _depositor,
    uint256 _depositAmount,
    address _delegatee,
    address _firstClaimer,
    address _newClaimer
  ) public {
    vm.assume(_newClaimer != address(0) && _newClaimer != _firstClaimer);

    GovernanceStaker.DepositIdentifier _depositId;
    (_depositAmount, _depositId) =
      _boundMintAndStake(_depositor, _depositAmount, _delegatee, _firstClaimer);

    vm.expectEmit();
    emit GovernanceStaker.ClaimerAltered(_depositId, _firstClaimer, _newClaimer);

    vm.prank(_depositor);
    govStaker.alterClaimer(_depositId, _newClaimer);
  }

  function testFuzz_UpdatesDepositsEarningPower(
    address _depositor,
    uint256 _depositAmount,
    address _delegatee,
    address _firstClaimer,
    address _newClaimer,
    uint96 _newEarningPower
  ) public {
    vm.assume(_newClaimer != address(0) && _newClaimer != _firstClaimer);

    GovernanceStaker.DepositIdentifier _depositId;
    (_depositAmount, _depositId) =
      _boundMintAndStake(_depositor, _depositAmount, _delegatee, _firstClaimer);

    earningPowerCalculator.__setEarningPowerAndIsQualifiedForDelegatee(
      _delegatee, _newEarningPower, true
    );

    vm.prank(_depositor);
    govStaker.alterClaimer(_depositId, _newClaimer);

    GovernanceStaker.Deposit memory _deposit = _fetchDeposit(_depositId);

    assertEq(_deposit.earningPower, _newEarningPower);
  }

  function testFuzz_UpdatesGlobalTotalEarningPower(
    address _depositor,
    uint256 _depositAmount,
    address _delegatee,
    address _firstClaimer,
    address _newClaimer,
    uint96 _newEarningPower
  ) public {
    vm.assume(_newClaimer != address(0) && _newClaimer != _firstClaimer);

    GovernanceStaker.DepositIdentifier _depositId;
    (_depositAmount, _depositId) =
      _boundMintAndStake(_depositor, _depositAmount, _delegatee, _firstClaimer);

    earningPowerCalculator.__setEarningPowerAndIsQualifiedForDelegatee(
      _delegatee, _newEarningPower, true
    );

    vm.prank(_depositor);
    govStaker.alterClaimer(_depositId, _newClaimer);

    assertEq(govStaker.totalEarningPower(), _newEarningPower);
  }

  function testFuzz_UpdatesDepositorsTotalEarningPower(
    address _depositor,
    uint256 _depositAmount,
    address _delegatee,
    address _firstClaimer,
    address _newClaimer,
    uint96 _newEarningPower
  ) public {
    vm.assume(_newClaimer != address(0) && _newClaimer != _firstClaimer);

    GovernanceStaker.DepositIdentifier _depositId;
    (_depositAmount, _depositId) =
      _boundMintAndStake(_depositor, _depositAmount, _delegatee, _firstClaimer);

    earningPowerCalculator.__setEarningPowerAndIsQualifiedForDelegatee(
      _delegatee, _newEarningPower, true
    );

    vm.prank(_depositor);
    govStaker.alterClaimer(_depositId, _newClaimer);

    assertEq(govStaker.totalEarningPower(), _newEarningPower);
  }

  function testFuzz_RevertIf_TheCallerIsNotTheDepositor(
    address _depositor,
    address _notDepositor,
    uint256 _depositAmount,
    address _delegatee,
    address _firstClaimer,
    address _newClaimer
  ) public {
    vm.assume(
      _notDepositor != _depositor && _newClaimer != address(0) && _newClaimer != _firstClaimer
    );

    GovernanceStaker.DepositIdentifier _depositId;
    (_depositAmount, _depositId) =
      _boundMintAndStake(_depositor, _depositAmount, _delegatee, _firstClaimer);

    vm.prank(_notDepositor);
    vm.expectRevert(
      abi.encodeWithSelector(
        GovernanceStaker.GovernanceStaker__Unauthorized.selector,
        bytes32("not owner"),
        _notDepositor
      )
    );
    govStaker.alterClaimer(_depositId, _newClaimer);
  }

  function testFuzz_RevertIf_TheDepositIdentifierIsInvalid(
    address _depositor,
    GovernanceStaker.DepositIdentifier _depositId,
    address _newClaimer
  ) public {
    vm.assume(_depositor != address(0) && _newClaimer != address(0));

    // Since no deposits have been made yet, all DepositIdentifiers are invalid, and any call to
    // alter one should revert. We rely on the default owner of any uninitialized deposit being
    // address zero, which means the address attempting to alter it won't be able to.
    vm.prank(_depositor);
    vm.expectRevert(
      abi.encodeWithSelector(
        GovernanceStaker.GovernanceStaker__Unauthorized.selector, bytes32("not owner"), _depositor
      )
    );
    govStaker.alterClaimer(_depositId, _newClaimer);
  }

  function testFuzz_RevertIf_ClaimerIsTheZeroAddress(
    address _depositor,
    uint256 _depositAmount,
    address _delegatee
  ) public {
    GovernanceStaker.DepositIdentifier _depositId;
    (_depositAmount, _depositId) = _boundMintAndStake(_depositor, _depositAmount, _delegatee);

    vm.prank(_depositor);
    vm.expectRevert(GovernanceStaker.GovernanceStaker__InvalidAddress.selector);
    govStaker.alterClaimer(_depositId, address(0));
  }

  function testFuzz_SetsScaledEarningPowerWhenCalculatorScalesStakeAmount(
    address _depositor,
    uint256 _depositAmount,
    address _delegatee,
    address _firstClaimer,
    address _newClaimer,
    uint256 _multiplierBips
  ) public {
    vm.assume(_newClaimer != address(0) && _newClaimer != _firstClaimer);

    _multiplierBips = bound(_multiplierBips, 0, 20_000);
    earningPowerCalculator.__setMultiplierBips(_multiplierBips);

    GovernanceStaker.DepositIdentifier _depositId;
    (_depositAmount, _depositId) =
      _boundMintAndStake(_depositor, _depositAmount, _delegatee, _firstClaimer);

    vm.prank(_depositor);
    govStaker.alterClaimer(_depositId, _newClaimer);

    uint256 _expectedEarningPower = (_depositAmount * _multiplierBips) / 10_000;

    GovernanceStaker.Deposit memory _deposit = _fetchDeposit(_depositId);
    assertEq(_deposit.earningPower, _expectedEarningPower);
    assertEq(govStaker.totalEarningPower(), _expectedEarningPower);
    assertEq(govStaker.depositorTotalEarningPower(_depositor), _expectedEarningPower);
  }

  function testFuzz_SetsFixedEarningPowerWhenCalculatorReturnsConstantAmount(
    address _depositor,
    uint256 _depositAmount,
    address _delegatee,
    address _firstClaimer,
    address _newClaimer,
    uint256 _fixedEarningPower
  ) public {
    vm.assume(_newClaimer != address(0) && _newClaimer != _firstClaimer);

    _fixedEarningPower = _boundToRealisticStake(_fixedEarningPower);
    earningPowerCalculator.__setFixedReturn(_fixedEarningPower);

    GovernanceStaker.DepositIdentifier _depositId;
    (_depositAmount, _depositId) =
      _boundMintAndStake(_depositor, _depositAmount, _delegatee, _firstClaimer);

    vm.prank(_depositor);
    govStaker.alterClaimer(_depositId, _newClaimer);

    GovernanceStaker.Deposit memory _deposit = _fetchDeposit(_depositId);
    assertEq(_deposit.earningPower, _fixedEarningPower);
    assertEq(govStaker.totalEarningPower(), _fixedEarningPower);
    assertEq(govStaker.depositorTotalEarningPower(_depositor), _fixedEarningPower);
  }
}

contract Withdraw is GovernanceStakerTest {
  function testFuzz_AllowsDepositorToWithdrawStake(
    address _depositor,
    uint256 _depositAmount,
    address _delegatee,
    uint256 _withdrawalAmount
  ) public {
    GovernanceStaker.DepositIdentifier _depositId;
    (_depositAmount, _depositId) = _boundMintAndStake(_depositor, _depositAmount, _delegatee);
    _withdrawalAmount = bound(_withdrawalAmount, 0, _depositAmount);

    vm.prank(_depositor);
    govStaker.withdraw(_depositId, _withdrawalAmount);

    GovernanceStaker.Deposit memory _deposit = _fetchDeposit(_depositId);
    address _surrogate = address(govStaker.surrogates(_deposit.delegatee));

    assertEq(govToken.balanceOf(_depositor), _withdrawalAmount);
    assertEq(_deposit.balance, _depositAmount - _withdrawalAmount);
    assertEq(govToken.balanceOf(_surrogate), _depositAmount - _withdrawalAmount);
  }

  function testFuzz_UpdatesTheTotalStakedWhenAnAccountWithdraws(
    address _depositor,
    uint256 _depositAmount,
    address _delegatee,
    uint256 _withdrawalAmount
  ) public {
    GovernanceStaker.DepositIdentifier _depositId;
    (_depositAmount, _depositId) = _boundMintAndStake(_depositor, _depositAmount, _delegatee);
    _withdrawalAmount = bound(_withdrawalAmount, 0, _depositAmount);

    vm.prank(_depositor);
    govStaker.withdraw(_depositId, _withdrawalAmount);

    assertEq(govStaker.totalStaked(), _depositAmount - _withdrawalAmount);
  }

  function testFuzz_UpdatesTheTotalStakedWhenTwoAccountsWithdraw(
    address _depositor1,
    uint256 _depositAmount1,
    address _delegatee1,
    address _depositor2,
    uint256 _depositAmount2,
    address _delegatee2,
    uint256 _withdrawalAmount1,
    uint256 _withdrawalAmount2
  ) public {
    // Make two separate deposits
    GovernanceStaker.DepositIdentifier _depositId1;
    (_depositAmount1, _depositId1) = _boundMintAndStake(_depositor1, _depositAmount1, _delegatee1);
    GovernanceStaker.DepositIdentifier _depositId2;
    (_depositAmount2, _depositId2) = _boundMintAndStake(_depositor2, _depositAmount2, _delegatee2);

    // Calculate withdrawal amounts
    _withdrawalAmount1 = bound(_withdrawalAmount1, 0, _depositAmount1);
    _withdrawalAmount2 = bound(_withdrawalAmount2, 0, _depositAmount2);

    // Execute both withdrawals
    vm.prank(_depositor1);
    govStaker.withdraw(_depositId1, _withdrawalAmount1);
    vm.prank(_depositor2);
    govStaker.withdraw(_depositId2, _withdrawalAmount2);

    uint256 _remainingDeposits =
      _depositAmount1 + _depositAmount2 - _withdrawalAmount1 - _withdrawalAmount2;
    assertEq(govStaker.totalStaked(), _remainingDeposits);
  }

  function testFuzz_UpdatesAnAccountsTotalStakedWhenItWithdrawals(
    address _depositor,
    uint256 _depositAmount1,
    uint256 _depositAmount2,
    address _delegatee1,
    address _delegatee2,
    uint256 _withdrawalAmount
  ) public {
    // Make two separate deposits
    GovernanceStaker.DepositIdentifier _depositId1;
    (_depositAmount1, _depositId1) = _boundMintAndStake(_depositor, _depositAmount1, _delegatee1);
    GovernanceStaker.DepositIdentifier _depositId2;
    (_depositAmount2, _depositId2) = _boundMintAndStake(_depositor, _depositAmount2, _delegatee2);

    // Withdraw part of the first deposit
    _withdrawalAmount = bound(_withdrawalAmount, 0, _depositAmount1);
    vm.prank(_depositor);
    govStaker.withdraw(_depositId1, _withdrawalAmount);

    // Ensure the account's total balance + global balance accounting have been updated
    assertEq(
      govStaker.depositorTotalStaked(_depositor),
      _depositAmount1 + _depositAmount2 - _withdrawalAmount
    );
    assertEq(govStaker.totalStaked(), _depositAmount1 + _depositAmount2 - _withdrawalAmount);
  }

  function testFuzz_UpdatesAnAccountsTotalEarningPowerWhenItWithdrawals(
    address _depositor,
    uint256 _depositAmount1,
    uint256 _depositAmount2,
    address _delegatee1,
    address _delegatee2,
    uint256 _withdrawalAmount
  ) public {
    // Make two separate deposits
    GovernanceStaker.DepositIdentifier _depositId1;
    (_depositAmount1, _depositId1) = _boundMintAndStake(_depositor, _depositAmount1, _delegatee1);
    GovernanceStaker.DepositIdentifier _depositId2;
    (_depositAmount2, _depositId2) = _boundMintAndStake(_depositor, _depositAmount2, _delegatee2);

    // Withdraw part of the first deposit
    _withdrawalAmount = uint256(bound(_withdrawalAmount, 0, _depositAmount1));
    vm.prank(_depositor);
    govStaker.withdraw(_depositId1, _withdrawalAmount);

    // Ensure the account's total balance + global balance accounting have been updated
    assertEq(
      govStaker.depositorTotalEarningPower(_depositor),
      _depositAmount1 + _depositAmount2 - _withdrawalAmount
    );
    assertEq(govStaker.totalEarningPower(), _depositAmount1 + _depositAmount2 - _withdrawalAmount);
  }

  function testFuzz_EmitsAnEventWhenThereIsAWithdrawal(
    address _depositor,
    uint256 _depositAmount,
    address _delegatee,
    uint256 _withdrawalAmount
  ) public {
    GovernanceStaker.DepositIdentifier _depositId;
    (_depositAmount, _depositId) = _boundMintAndStake(_depositor, _depositAmount, _delegatee);
    _withdrawalAmount = bound(_withdrawalAmount, 0, _depositAmount);

    vm.expectEmit();
    emit GovernanceStaker.StakeWithdrawn(
      _depositor, _depositId, _withdrawalAmount, _depositAmount - _withdrawalAmount
    );

    vm.prank(_depositor);
    govStaker.withdraw(_depositId, _withdrawalAmount);
  }

  function testFuzz_RevertIf_TheWithdrawerIsNotTheDepositor(
    address _depositor,
    uint256 _amount,
    address _delegatee,
    address _notDepositor
  ) public {
    GovernanceStaker.DepositIdentifier _depositId;
    (_amount, _depositId) = _boundMintAndStake(_depositor, _amount, _delegatee);
    vm.assume(_depositor != _notDepositor);

    vm.prank(_notDepositor);
    vm.expectRevert(
      abi.encodeWithSelector(
        GovernanceStaker.GovernanceStaker__Unauthorized.selector,
        bytes32("not owner"),
        _notDepositor
      )
    );
    govStaker.withdraw(_depositId, _amount);
  }

  function testFuzz_RevertIf_TheWithdrawalAmountIsGreaterThanTheBalance(
    address _depositor,
    uint256 _amount,
    uint256 _amountOver,
    address _delegatee
  ) public {
    GovernanceStaker.DepositIdentifier _depositId;
    (_amount, _depositId) = _boundMintAndStake(_depositor, _amount, _delegatee);
    _amountOver = bound(_amountOver, 1, type(uint128).max);

    vm.prank(_depositor);
    vm.expectRevert();
    govStaker.withdraw(_depositId, _amount + _amountOver);
  }

  function testFuzz_SetsScaledEarningPowerWhenCalculatorScalesStakeAmount(
    address _depositor,
    uint256 _depositAmount,
    address _delegatee,
    uint256 _withdrawalAmount,
    uint256 _multiplierBips
  ) public {
    _multiplierBips = bound(_multiplierBips, 0, 20_000);
    earningPowerCalculator.__setMultiplierBips(_multiplierBips);

    GovernanceStaker.DepositIdentifier _depositId;
    (_depositAmount, _depositId) = _boundMintAndStake(_depositor, _depositAmount, _delegatee);
    _withdrawalAmount = bound(_withdrawalAmount, 0, _depositAmount);

    vm.prank(_depositor);
    govStaker.withdraw(_depositId, _withdrawalAmount);

    GovernanceStaker.Deposit memory _deposit = _fetchDeposit(_depositId);
    uint256 _remainingStake = _depositAmount - _withdrawalAmount;
    uint256 _expectedEarningPower = (_remainingStake * _multiplierBips) / 10_000;
    assertEq(_deposit.earningPower, _expectedEarningPower);
  }

  function testFuzz_SetsFixedEarningPowerWhenCalculatorReturnsConstantAmount(
    address _depositor,
    uint256 _depositAmount,
    address _delegatee,
    uint256 _withdrawalAmount,
    uint256 _fixedEarningPower
  ) public {
    _fixedEarningPower = _boundToRealisticStake(_fixedEarningPower);
    earningPowerCalculator.__setFixedReturn(_fixedEarningPower);

    GovernanceStaker.DepositIdentifier _depositId;
    (_depositAmount, _depositId) = _boundMintAndStake(_depositor, _depositAmount, _delegatee);
    _withdrawalAmount = bound(_withdrawalAmount, 0, _depositAmount);

    vm.prank(_depositor);
    govStaker.withdraw(_depositId, _withdrawalAmount);

    GovernanceStaker.Deposit memory _deposit = _fetchDeposit(_depositId);
    assertEq(_deposit.earningPower, _fixedEarningPower);
  }
}

contract SetRewardNotifier is GovernanceStakerTest {
  function testFuzz_AllowsAdminToSetRewardNotifier(address _rewardNotifier, bool _isEnabled) public {
    vm.prank(admin);
    govStaker.setRewardNotifier(_rewardNotifier, _isEnabled);

    assertEq(govStaker.isRewardNotifier(_rewardNotifier), _isEnabled);
  }

  function test_AllowsTheAdminToDisableAnActiveRewardNotifier() public {
    vm.prank(admin);
    govStaker.setRewardNotifier(rewardNotifier, false);

    assertFalse(govStaker.isRewardNotifier(rewardNotifier));
  }

  function testFuzz_EmitsEventWhenRewardNotifierIsSet(address _rewardNotifier, bool _isEnabled)
    public
  {
    vm.expectEmit();
    emit RewardNotifierSet(_rewardNotifier, _isEnabled);
    vm.prank(admin);
    govStaker.setRewardNotifier(_rewardNotifier, _isEnabled);
  }

  function testFuzz_RevertIf_TheCallerIsNotTheAdmin(
    address _notAdmin,
    address _newRewardNotifier,
    bool _isEnabled
  ) public {
    vm.assume(_notAdmin != govStaker.admin());

    vm.prank(_notAdmin);
    vm.expectRevert(
      abi.encodeWithSelector(
        GovernanceStaker.GovernanceStaker__Unauthorized.selector, bytes32("not admin"), _notAdmin
      )
    );
    govStaker.setRewardNotifier(_newRewardNotifier, _isEnabled);
  }
}

contract SetAdmin is GovernanceStakerTest {
  function testFuzz_AllowsAdminToSetAdmin(address _newAdmin) public {
    vm.assume(_newAdmin != address(0));

    vm.prank(admin);
    govStaker.setAdmin(_newAdmin);

    assertEq(govStaker.admin(), _newAdmin);
  }

  function testFuzz_EmitsEventWhenAdminIsSet(address _newAdmin) public {
    vm.assume(_newAdmin != address(0));

    vm.expectEmit();
    emit AdminSet(admin, _newAdmin);

    vm.prank(admin);
    govStaker.setAdmin(_newAdmin);
  }

  function testFuzz_RevertIf_TheCallerIsNotTheAdmin(address _notAdmin, address _newAdmin) public {
    vm.assume(_notAdmin != govStaker.admin());

    vm.prank(_notAdmin);
    vm.expectRevert(
      abi.encodeWithSelector(
        GovernanceStaker.GovernanceStaker__Unauthorized.selector, bytes32("not admin"), _notAdmin
      )
    );
    govStaker.setAdmin(_newAdmin);
  }

  function test_RevertIf_NewAdminAddressIsZeroAddress() public {
    vm.prank(admin);
    vm.expectRevert(GovernanceStaker.GovernanceStaker__InvalidAddress.selector);
    govStaker.setAdmin(address(0));
  }
}

contract SetEarningPowerCalculator is GovernanceStakerTest {
  function testFuzz_AllowsAdminToSetEarningPowerCalculator(address _newEarningPowerCalculator)
    public
  {
    vm.assume(_newEarningPowerCalculator != address(0));

    vm.prank(admin);
    govStaker.setEarningPowerCalculator(_newEarningPowerCalculator);

    assertEq(address(govStaker.earningPowerCalculator()), _newEarningPowerCalculator);
  }

  function testFuzz_EmitsEventWhenEarningPowerCalculatorIsSet(address _newEarningPowerCalculator)
    public
  {
    vm.assume(_newEarningPowerCalculator != address(0));

    vm.expectEmit();
    emit GovernanceStaker.EarningPowerCalculatorSet(
      address(govStaker.earningPowerCalculator()), _newEarningPowerCalculator
    );

    vm.prank(admin);
    govStaker.setEarningPowerCalculator(_newEarningPowerCalculator);
  }

  function testFuzz_RevertIf_TheCallerIsNotTheAdmin(
    address _notAdmin,
    address _newEarningPowerCalculator
  ) public {
    vm.assume(_notAdmin != govStaker.admin());

    vm.prank(_notAdmin);
    vm.expectRevert(
      abi.encodeWithSelector(
        GovernanceStaker.GovernanceStaker__Unauthorized.selector, bytes32("not admin"), _notAdmin
      )
    );
    govStaker.setEarningPowerCalculator(_newEarningPowerCalculator);
  }

  function test_RevertIf_NewEarningPowerCalculatorAddressIsZeroAddress() public {
    vm.prank(admin);
    vm.expectRevert(GovernanceStaker.GovernanceStaker__InvalidAddress.selector);
    govStaker.setEarningPowerCalculator(address(0));
  }
}

contract SetClaimFeeParameters is GovernanceStakerTest {
  function testFuzz_AllowsAdminToUpdateTheClaimFeeAmountAndFeeCollector(
    GovernanceStaker.ClaimFeeParameters memory _newParams
  ) public {
    vm.assume(_newParams.feeCollector != address(0));
    _newParams.feeAmount = uint96(bound(_newParams.feeAmount, 0, govStaker.MAX_CLAIM_FEE()));

    vm.prank(admin);
    govStaker.setClaimFeeParameters(_newParams);

    (uint96 _feeAmount, address _feeCollector) = govStaker.claimFeeParameters();
    assertEq(_feeAmount, _newParams.feeAmount);
    assertEq(_feeCollector, _newParams.feeCollector);
  }

  function testFuzz_AllowsAdminToSetFeeAmountAndFeeCollectorToZero(
    GovernanceStaker.ClaimFeeParameters memory _initialParams
  ) public {
    vm.assume(_initialParams.feeCollector != address(0));
    _initialParams.feeAmount = uint96(bound(_initialParams.feeAmount, 0, govStaker.MAX_CLAIM_FEE()));

    // Establish some initial parameters.
    vm.prank(admin);
    govStaker.setClaimFeeParameters(_initialParams);

    GovernanceStaker.ClaimFeeParameters memory _zeroParams =
      GovernanceStaker.ClaimFeeParameters({feeAmount: 0, feeCollector: address(0)});

    // Update the parameters to both be zero.
    vm.prank(admin);
    govStaker.setClaimFeeParameters(_zeroParams);

    (uint96 _feeAmount, address _feeCollector) = govStaker.claimFeeParameters();
    assertEq(_feeAmount, 0);
    assertEq(_feeCollector, address(0));
  }

  function testFuzz_EmitsAClaimFeeParametersSetEvent(
    GovernanceStaker.ClaimFeeParameters memory _initialParams,
    GovernanceStaker.ClaimFeeParameters memory _newParams
  ) public {
    vm.assume(_initialParams.feeCollector != address(0) && _newParams.feeCollector != address(0));
    _newParams.feeAmount = uint96(bound(_newParams.feeAmount, 0, govStaker.MAX_CLAIM_FEE()));
    _initialParams.feeAmount = uint96(bound(_initialParams.feeAmount, 0, govStaker.MAX_CLAIM_FEE()));

    // Establish initial non-zero params.
    vm.prank(admin);
    govStaker.setClaimFeeParameters(_initialParams);

    // Update params, expecting appropriate event.
    vm.prank(admin);
    vm.expectEmit();
    emit GovernanceStaker.ClaimFeeParametersSet(
      _initialParams.feeAmount,
      _newParams.feeAmount,
      _initialParams.feeCollector,
      _newParams.feeCollector
    );
    govStaker.setClaimFeeParameters(_newParams);
  }

  function testFuzz_RevertIf_FeeAmountIsMoreThanTheMaxClaimFee(
    GovernanceStaker.ClaimFeeParameters memory _newParams
  ) public {
    vm.assume(_newParams.feeCollector != address(0));
    _newParams.feeAmount =
      uint96(bound(_newParams.feeAmount, govStaker.MAX_CLAIM_FEE() + 1, type(uint96).max));

    vm.prank(admin);
    vm.expectRevert(GovernanceStaker.GovernanceStaker__InvalidClaimFeeParameters.selector);
    govStaker.setClaimFeeParameters(_newParams);
  }

  function testFuzz_RevertIf_TheFeeCollectorIsAddressZeroWhileFeeAmountIsNotZero(
    GovernanceStaker.ClaimFeeParameters memory _newParams
  ) public {
    _newParams.feeAmount = uint96(bound(_newParams.feeAmount, 1, govStaker.MAX_CLAIM_FEE()));
    _newParams.feeCollector = address(0);

    vm.prank(admin);
    vm.expectRevert(GovernanceStaker.GovernanceStaker__InvalidClaimFeeParameters.selector);
    govStaker.setClaimFeeParameters(_newParams);
  }

  function testFuzz_RevertIf_TheCallerIsNotTheAdmin(
    address _notAdmin,
    GovernanceStaker.ClaimFeeParameters memory _newParams
  ) public {
    vm.assume(_newParams.feeCollector != address(0));
    vm.assume(_notAdmin != admin);
    _newParams.feeAmount = uint96(bound(_newParams.feeAmount, 0, govStaker.MAX_CLAIM_FEE()));

    vm.prank(_notAdmin);
    vm.expectRevert(
      abi.encodeWithSelector(
        GovernanceStaker.GovernanceStaker__Unauthorized.selector, bytes32("not admin"), _notAdmin
      )
    );
    govStaker.setClaimFeeParameters(_newParams);
  }
}

contract GovernanceStakerRewardsTest is GovernanceStakerTest {
  // Helper methods for dumping contract state related to rewards calculation for debugging
  function __dumpDebugGlobalRewards() public view {
    console2.log("reward balance");
    console2.log(rewardToken.balanceOf(address(govStaker)));
    console2.log("rewardDuration");
    console2.log(govStaker.REWARD_DURATION());
    console2.log("rewardEndTime");
    console2.log(govStaker.rewardEndTime());
    console2.log("lastCheckpointTime");
    console2.log(govStaker.lastCheckpointTime());
    console2.log("totalStake");
    console2.log(govStaker.totalStaked());
    console2.log("scaledRewardRate");
    console2.log(govStaker.scaledRewardRate());
    console2.log("block.timestamp");
    console2.log(block.timestamp);
    console2.log("rewardPerTokenAccumulatedCheckpoint");
    console2.log(govStaker.rewardPerTokenAccumulatedCheckpoint());
    console2.log("lastTimeRewardDistributed()");
    console2.log(govStaker.lastTimeRewardDistributed());
    console2.log("rewardPerTokenAccumulated()");
    console2.log(govStaker.rewardPerTokenAccumulated());
    console2.log("-----------------------------------------------");
  }

  function __dumpDebugDeposit(GovernanceStaker.DepositIdentifier _depositId) public view {
    GovernanceStaker.Deposit memory _deposit = _fetchDeposit(_depositId);
    console2.log("deposit balance");
    console2.log(_deposit.balance);
    console2.log("deposit owner");
    console2.log(_deposit.owner);
    console2.log("deposit claimer");
    console2.log(_deposit.claimer);
    console2.log("deposit earningPower");
    console2.log(_deposit.earningPower);
    console2.log("deposit reward per token checkpoint");
    console2.log(_deposit.rewardPerTokenCheckpoint);
    console2.log("deposit scaled unclaimed reward checkpoint");
    console2.log(_deposit.scaledUnclaimedRewardCheckpoint);
    console2.log("deposit unclaimed rewards");
    console2.log(govStaker.unclaimedReward(_depositId));
  }

  function _jumpAheadByPercentOfRewardDuration(uint256 _percent) public {
    uint256 _seconds = (_percent * govStaker.REWARD_DURATION()) / 100;
    _jumpAhead(_seconds);
  }

  function _boundToRealisticReward(uint256 _rewardAmount)
    public
    pure
    returns (uint256 _boundedRewardAmount)
  {
    _boundedRewardAmount = bound(_rewardAmount, 200e6, 10_000_000e18);
  }

  function _boundToRealisticStakeAndReward(uint256 _stakeAmount, uint256 _rewardAmount)
    public
    pure
    returns (uint96 _boundedStakeAmount, uint256 _boundedRewardAmount)
  {
    _boundedStakeAmount = uint96(_boundToRealisticStake(_stakeAmount));
    _boundedRewardAmount = _boundToRealisticReward(_rewardAmount);
  }

  function _mintTransferAndNotifyReward(uint256 _amount) public {
    rewardToken.mint(rewardNotifier, _amount);

    vm.startPrank(rewardNotifier);
    rewardToken.transfer(address(govStaker), _amount);
    govStaker.notifyRewardAmount(_amount);
    vm.stopPrank();
  }

  function _mintTransferAndNotifyReward(address _rewardNotifier, uint256 _amount) public {
    vm.assume(_rewardNotifier != address(0));
    rewardToken.mint(_rewardNotifier, _amount);

    vm.startPrank(_rewardNotifier);
    rewardToken.transfer(address(govStaker), _amount);
    govStaker.notifyRewardAmount(_amount);
    vm.stopPrank();
  }
}

contract NotifyRewardAmount is GovernanceStakerRewardsTest {
  function testFuzz_UpdatesTheRewardRate(uint256 _amount) public {
    _amount = _boundToRealisticReward(_amount);
    _mintTransferAndNotifyReward(_amount);

    uint256 _expectedRewardRate = (SCALE_FACTOR * _amount) / govStaker.REWARD_DURATION();
    assertEq(govStaker.scaledRewardRate(), _expectedRewardRate);
  }

  function testFuzz_UpdatesTheRewardRateOnASecondCall(uint256 _amount1, uint256 _amount2) public {
    _amount1 = _boundToRealisticReward(_amount1);
    _amount2 = _boundToRealisticReward(_amount2);

    _mintTransferAndNotifyReward(_amount1);
    uint256 _expectedRewardRate = (SCALE_FACTOR * _amount1) / govStaker.REWARD_DURATION();
    assertEq(govStaker.scaledRewardRate(), _expectedRewardRate);

    _mintTransferAndNotifyReward(_amount2);
    _expectedRewardRate = (SCALE_FACTOR * (_amount1 + _amount2)) / govStaker.REWARD_DURATION();
    assertLteWithinOneUnit(govStaker.scaledRewardRate(), _expectedRewardRate);
  }

  function testFuzz_UpdatesTheAccumulatorTimestamps(uint256 _amount, uint256 _jumpTime) public {
    _amount = _boundToRealisticReward(_amount);
    _jumpTime = bound(_jumpTime, 0, 50_000 days); // prevent overflow in timestamps
    uint256 _futureTimestamp = block.timestamp + _jumpTime;
    _jumpAhead(_jumpTime);

    _mintTransferAndNotifyReward(_amount);
    uint256 _expectedFinishTimestamp = _futureTimestamp + govStaker.REWARD_DURATION();

    assertEq(govStaker.lastCheckpointTime(), _futureTimestamp);
    assertEq(govStaker.rewardEndTime(), _expectedFinishTimestamp);
  }

  function testFuzz_UpdatesTheCheckpointedRewardPerTokenAccumulator(
    address _depositor,
    address _delegatee,
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    uint256 _durationPercent
  ) public {
    // In order to force calculation of a non-zero, there must be some staked supply, so we do
    // that deposit first
    (_stakeAmount, _rewardAmount) = _boundToRealisticStakeAndReward(_stakeAmount, _rewardAmount);
    _boundMintAndStake(_depositor, _stakeAmount, _delegatee);
    // We will jump ahead by some percentage of the duration
    _durationPercent = bound(_durationPercent, 1, 100);

    // Now the contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);
    // Some time elapses
    _jumpAheadByPercentOfRewardDuration(_durationPercent);
    // We make another reward which should write the non-zero reward amount
    _mintTransferAndNotifyReward(_rewardAmount);
    // Sanity check on our test assumptions
    require(
      govStaker.rewardPerTokenAccumulated() != 0,
      "Broken test assumption: expecting a non-zero reward accumulator"
    );

    // We are not testing the calculation of the reward amount, but only that the value in storage
    // has been updated on reward notification and thus matches the "live" calculation.
    assertEq(govStaker.rewardPerTokenAccumulatedCheckpoint(), govStaker.rewardPerTokenAccumulated());
  }

  function testFuzz_AllowsMultipleApprovedRewardNotifiersToNotifyOfRewards(
    uint256 _amount1,
    uint256 _amount2,
    uint256 _amount3,
    address _rewardNotifier1,
    address _rewardNotifier2,
    address _rewardNotifier3
  ) public {
    _amount1 = _boundToRealisticReward(_amount1);
    _amount2 = _boundToRealisticReward(_amount2);
    _amount3 = _boundToRealisticReward(_amount3);

    vm.startPrank(admin);
    govStaker.setRewardNotifier(_rewardNotifier1, true);
    govStaker.setRewardNotifier(_rewardNotifier2, true);
    govStaker.setRewardNotifier(_rewardNotifier3, true);
    vm.stopPrank();

    // The first notifier notifies
    _mintTransferAndNotifyReward(_rewardNotifier1, _amount1);

    // The second notifier notifies
    _mintTransferAndNotifyReward(_rewardNotifier2, _amount2);

    // The third notifier notifies
    _mintTransferAndNotifyReward(_rewardNotifier3, _amount3);
    uint256 _expectedRewardRate =
      (SCALE_FACTOR * (_amount1 + _amount2 + _amount3)) / govStaker.REWARD_DURATION();
    // because we summed 3 amounts, the rounding error can be as much as 2 units
    assertApproxEqAbs(govStaker.scaledRewardRate(), _expectedRewardRate, 2);
    assertLe(govStaker.scaledRewardRate(), _expectedRewardRate);
  }

  function testFuzz_EmitsAnEventWhenRewardsAreNotified(uint256 _amount) public {
    _amount = _boundToRealisticReward(_amount);
    rewardToken.mint(rewardNotifier, _amount);

    vm.startPrank(rewardNotifier);
    rewardToken.transfer(address(govStaker), _amount);

    vm.expectEmit();
    emit GovernanceStaker.RewardNotified(_amount, rewardNotifier);

    govStaker.notifyRewardAmount(_amount);
    vm.stopPrank();
  }

  function testFuzz_RevertIf_CallerIsNotTheRewardNotifier(uint256 _amount, address _notNotifier)
    public
  {
    vm.assume(!govStaker.isRewardNotifier(_notNotifier) && _notNotifier != address(0));
    _amount = _boundToRealisticReward(_amount);

    rewardToken.mint(_notNotifier, _amount);

    vm.startPrank(_notNotifier);
    rewardToken.transfer(address(govStaker), _amount);
    vm.expectRevert(
      abi.encodeWithSelector(
        GovernanceStaker.GovernanceStaker__Unauthorized.selector,
        bytes32("not notifier"),
        _notNotifier
      )
    );
    govStaker.notifyRewardAmount(_amount);
    vm.stopPrank();
  }

  function testFuzz_RevertIf_RewardAmountIsTooSmall(uint256 _amount) public {
    // If the amount is less than the rewards duration the reward rate will be truncated to 0
    _amount = bound(_amount, 0, govStaker.REWARD_DURATION() - 1);
    rewardToken.mint(rewardNotifier, _amount);

    vm.startPrank(rewardNotifier);
    rewardToken.transfer(address(govStaker), _amount);
    vm.expectRevert(GovernanceStaker.GovernanceStaker__InvalidRewardRate.selector);
    govStaker.notifyRewardAmount(_amount);
    vm.stopPrank();
  }

  function testFuzz_RevertIf_InsufficientRewardsAreTransferredToContract(
    uint256 _amount,
    uint256 _transferPercent
  ) public {
    _amount = _boundToRealisticReward(_amount);
    // Transfer (at most) 99% of the reward amount. We calculate as a percentage rather than simply
    // an amount - 1 because rounding errors when calculating the reward rate, which favor the
    // staking contract can actually allow for something just below the amount to meet the criteria
    _transferPercent = _bound(_transferPercent, 1, 99);

    uint256 _transferAmount = _percentOf(_amount, _transferPercent);
    rewardToken.mint(rewardNotifier, _amount);

    vm.startPrank(rewardNotifier);
    // Something less than the supposed reward is sent
    rewardToken.transfer(address(govStaker), _transferAmount);
    // The reward notification should revert because the contract doesn't have enough tokens
    vm.expectRevert(GovernanceStaker.GovernanceStaker__InsufficientRewardBalance.selector);
    govStaker.notifyRewardAmount(_amount);
    vm.stopPrank();
  }
}

contract BumpEarningPower is GovernanceStakerRewardsTest {
  function testFuzz_BumpsTheDepositsEarningPowerUp(
    address _depositor,
    address _delegatee,
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    address _bumpCaller,
    address _tipReceiver,
    uint256 _requestedTip,
    uint96 _earningPowerIncrease
  ) public {
    vm.assume(_tipReceiver != address(0));
    _stakeAmount = _boundToRealisticStake(_stakeAmount);
    _rewardAmount = _boundToRealisticReward(_rewardAmount);
    _earningPowerIncrease = uint96(bound(_earningPowerIncrease, 1, type(uint48).max));

    // A user deposits staking tokens
    (, GovernanceStaker.DepositIdentifier _depositId) =
      _boundMintAndStake(_depositor, _stakeAmount, _delegatee);
    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);
    // The full duration passes
    _jumpAheadByPercentOfRewardDuration(101);
    // Tip must be less than the max bump, but also less than rewards for the sake of this test
    _requestedTip = bound(_requestedTip, 0, _min(maxBumpTip, govStaker.unclaimedReward(_depositId)));

    // The staker's earning power increases
    earningPowerCalculator.__setEarningPowerForDelegatee(
      _delegatee, _stakeAmount + _earningPowerIncrease
    );
    // Bump earning power is called
    vm.prank(_bumpCaller);
    govStaker.bumpEarningPower(_depositId, _tipReceiver, _requestedTip);

    (,, uint96 _newEarningPower,,,,) = govStaker.deposits(_depositId);
    assertEq(_newEarningPower, _stakeAmount + _earningPowerIncrease);
  }

  function testFuzz_BumpsTheGlobalTotalEarningPowerUp(
    address _depositor,
    address _delegatee,
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    address _bumpCaller,
    address _tipReceiver,
    uint256 _requestedTip,
    uint96 _earningPowerIncrease
  ) public {
    vm.assume(_tipReceiver != address(0));
    _stakeAmount = _boundToRealisticStake(_stakeAmount);
    _rewardAmount = _boundToRealisticReward(_rewardAmount);
    _earningPowerIncrease = uint96(bound(_earningPowerIncrease, 1, type(uint48).max));

    // A user deposits staking tokens
    (, GovernanceStaker.DepositIdentifier _depositId) =
      _boundMintAndStake(_depositor, _stakeAmount, _delegatee);
    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);
    // The full duration passes
    _jumpAheadByPercentOfRewardDuration(101);
    // Tip must be less than the max bump, but also less than rewards for the sake of this test
    _requestedTip = bound(_requestedTip, 0, _min(maxBumpTip, govStaker.unclaimedReward(_depositId)));

    // The staker's earning power increases
    earningPowerCalculator.__setEarningPowerForDelegatee(
      _delegatee, _stakeAmount + _earningPowerIncrease
    );
    // Bump earning power is called
    vm.prank(_bumpCaller);
    govStaker.bumpEarningPower(_depositId, _tipReceiver, _requestedTip);

    assertEq(govStaker.totalEarningPower(), _stakeAmount + _earningPowerIncrease);
  }

  function testFuzz_BumpsTheDepositorsTotalEarningPowerUp(
    address _depositor,
    address _delegatee,
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    address _bumpCaller,
    address _tipReceiver,
    uint256 _requestedTip,
    uint96 _earningPowerIncrease
  ) public {
    vm.assume(_tipReceiver != address(0));
    _stakeAmount = _boundToRealisticStake(_stakeAmount);
    _rewardAmount = _boundToRealisticReward(_rewardAmount);
    _earningPowerIncrease = uint96(bound(_earningPowerIncrease, 1, type(uint48).max));

    // A user deposits staking tokens
    (, GovernanceStaker.DepositIdentifier _depositId) =
      _boundMintAndStake(_depositor, _stakeAmount, _delegatee);
    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);
    // The full duration passes
    _jumpAheadByPercentOfRewardDuration(101);
    // Tip must be less than the max bump, but also less than rewards for the sake of this test
    _requestedTip = bound(_requestedTip, 0, _min(maxBumpTip, govStaker.unclaimedReward(_depositId)));

    // The staker's earning power increases
    earningPowerCalculator.__setEarningPowerForDelegatee(
      _delegatee, _stakeAmount + _earningPowerIncrease
    );
    // Bump earning power is called
    vm.prank(_bumpCaller);
    govStaker.bumpEarningPower(_depositId, _tipReceiver, _requestedTip);

    assertEq(govStaker.depositorTotalEarningPower(_depositor), _stakeAmount + _earningPowerIncrease);
  }

  function testFuzz_TransfersTipTokensToTheTipReceiverWhenEarningPowerIsBumpedUp(
    address _depositor,
    address _delegatee,
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    address _bumpCaller,
    address _tipReceiver,
    uint256 _requestedTip,
    uint96 _earningPowerIncrease
  ) public {
    vm.assume(_tipReceiver != address(0) && _tipReceiver != address(govStaker));
    _stakeAmount = _boundToRealisticStake(_stakeAmount);
    _rewardAmount = _boundToRealisticReward(_rewardAmount);
    uint256 _initialTipReceiverBalance = rewardToken.balanceOf(_tipReceiver);
    _earningPowerIncrease = uint96(bound(_earningPowerIncrease, 1, type(uint48).max));

    // A user deposits staking tokens
    (, GovernanceStaker.DepositIdentifier _depositId) =
      _boundMintAndStake(_depositor, _stakeAmount, _delegatee);
    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);
    // The full duration passes
    _jumpAheadByPercentOfRewardDuration(101);
    // Tip must be less than the max bump, but also less than rewards for the sake of this test
    _requestedTip = bound(_requestedTip, 0, _min(maxBumpTip, govStaker.unclaimedReward(_depositId)));

    // The staker's earning power increases
    earningPowerCalculator.__setEarningPowerForDelegatee(
      _delegatee, _stakeAmount + _earningPowerIncrease
    );
    // Bump earning power is called
    vm.prank(_bumpCaller);
    govStaker.bumpEarningPower(_depositId, _tipReceiver, _requestedTip);

    uint256 _tipReceiverBalanceIncrease =
      rewardToken.balanceOf(_tipReceiver) - _initialTipReceiverBalance;
    assertEq(_tipReceiverBalanceIncrease, _requestedTip);
  }

  function testFuzz_BumpsTheDepositsEarningPowerDown(
    address _depositor,
    address _delegatee,
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    address _bumpCaller,
    address _tipReceiver,
    uint256 _requestedTip,
    uint256 _earningPowerDecrease
  ) public {
    vm.assume(_tipReceiver != address(0));
    _stakeAmount = _boundToRealisticStake(_stakeAmount);
    _rewardAmount = bound(_rewardAmount, maxBumpTip + 1, 10_000_000e18);
    // Initial earning power for the mock calculator is equal to the amount staked
    _earningPowerDecrease = bound(_earningPowerDecrease, 1, _stakeAmount);

    // A user deposits staking tokens
    (, GovernanceStaker.DepositIdentifier _depositId) =
      _boundMintAndStake(_depositor, _stakeAmount, _delegatee);
    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);
    // The full duration passes
    _jumpAheadByPercentOfRewardDuration(101);
    // Tip must be less than the max bump, but also less than rewards for the sake of this test
    _requestedTip =
      bound(_requestedTip, 0, _min(maxBumpTip, govStaker.unclaimedReward(_depositId) - maxBumpTip));

    // The staker's earning power decreases
    earningPowerCalculator.__setEarningPowerForDelegatee(
      _delegatee, _stakeAmount - _earningPowerDecrease
    );
    // Bump earning power is called
    vm.prank(_bumpCaller);
    govStaker.bumpEarningPower(_depositId, _tipReceiver, _requestedTip);

    (,, uint96 _newEarningPower,,,,) = govStaker.deposits(_depositId);
    assertEq(_newEarningPower, _stakeAmount - _earningPowerDecrease);
  }

  function testFuzz_BumpsTheGlobalTotalEarningPowerDown(
    address _depositor,
    address _delegatee,
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    address _bumpCaller,
    address _tipReceiver,
    uint256 _requestedTip,
    uint256 _earningPowerDecrease
  ) public {
    vm.assume(_tipReceiver != address(0));
    _stakeAmount = _boundToRealisticStake(_stakeAmount);
    _rewardAmount = bound(_rewardAmount, maxBumpTip + 1, 10_000_000e18);
    _earningPowerDecrease = bound(_earningPowerDecrease, 1, _stakeAmount);

    // A user deposits staking tokens
    (, GovernanceStaker.DepositIdentifier _depositId) =
      _boundMintAndStake(_depositor, _stakeAmount, _delegatee);
    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);
    // The full duration passes
    _jumpAheadByPercentOfRewardDuration(101);
    // Tip must be less than the max bump, but also less than rewards for the sake of this test
    _requestedTip =
      bound(_requestedTip, 0, _min(maxBumpTip, govStaker.unclaimedReward(_depositId) - maxBumpTip));

    // The staker's earning power increases
    earningPowerCalculator.__setEarningPowerForDelegatee(
      _delegatee, _stakeAmount - _earningPowerDecrease
    );
    // Bump earning power is called
    vm.prank(_bumpCaller);
    govStaker.bumpEarningPower(_depositId, _tipReceiver, _requestedTip);

    assertEq(govStaker.totalEarningPower(), _stakeAmount - _earningPowerDecrease);
  }

  function testFuzz_BumpsTheDepositorsTotalEarningPowerDown(
    address _depositor,
    address _delegatee,
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    address _bumpCaller,
    address _tipReceiver,
    uint256 _requestedTip,
    uint256 _earningPowerDecrease
  ) public {
    vm.assume(_tipReceiver != address(0));
    _stakeAmount = _boundToRealisticStake(_stakeAmount);
    _rewardAmount = bound(_rewardAmount, maxBumpTip + 1, 10_000_000e18);
    _earningPowerDecrease = bound(_earningPowerDecrease, 1, _stakeAmount);

    // A user deposits staking tokens
    (, GovernanceStaker.DepositIdentifier _depositId) =
      _boundMintAndStake(_depositor, _stakeAmount, _delegatee);
    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);
    // The full duration passes
    _jumpAheadByPercentOfRewardDuration(101);
    // Tip must be less than the max bump, but also less than rewards for the sake of this test
    _requestedTip =
      bound(_requestedTip, 0, _min(maxBumpTip, govStaker.unclaimedReward(_depositId) - maxBumpTip));

    // The staker's earning power increases
    earningPowerCalculator.__setEarningPowerForDelegatee(
      _delegatee, _stakeAmount - _earningPowerDecrease
    );
    // Bump earning power is called
    vm.prank(_bumpCaller);
    govStaker.bumpEarningPower(_depositId, _tipReceiver, _requestedTip);

    assertEq(govStaker.depositorTotalEarningPower(_depositor), _stakeAmount - _earningPowerDecrease);
  }

  function testFuzz_TransfersTipTokensToTheTipReceiverWhenEarningPowerIsBumpedDown(
    address _depositor,
    address _delegatee,
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    address _bumpCaller,
    address _tipReceiver,
    uint256 _requestedTip,
    uint256 _earningPowerDecrease
  ) public {
    vm.assume(_tipReceiver != address(0) && _tipReceiver != address(govStaker));
    _stakeAmount = _boundToRealisticStake(_stakeAmount);
    _rewardAmount = bound(_rewardAmount, maxBumpTip + 1, 10_000_000e18);
    _earningPowerDecrease = bound(_earningPowerDecrease, 1, _stakeAmount);
    uint256 _initialTipReceiverBalance = rewardToken.balanceOf(_tipReceiver);

    // A user deposits staking tokens
    (, GovernanceStaker.DepositIdentifier _depositId) =
      _boundMintAndStake(_depositor, _stakeAmount, _delegatee);
    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);
    // The full duration passes
    _jumpAheadByPercentOfRewardDuration(101);
    // Tip must be less than the max bump, but also less than rewards for the sake of this test
    _requestedTip =
      bound(_requestedTip, 0, _min(maxBumpTip, govStaker.unclaimedReward(_depositId) - maxBumpTip));

    // The staker's earning power decreases
    earningPowerCalculator.__setEarningPowerForDelegatee(
      _delegatee, _stakeAmount - _earningPowerDecrease
    );
    // Bump earning power is called
    vm.prank(_bumpCaller);
    govStaker.bumpEarningPower(_depositId, _tipReceiver, _requestedTip);

    uint256 _tipReceiverBalanceIncrease =
      rewardToken.balanceOf(_tipReceiver) - _initialTipReceiverBalance;
    assertEq(_tipReceiverBalanceIncrease, _requestedTip);
  }

  function testFuzz_RevertIf_RequestedTipIsGreaterThanTheMaxTip(
    address _depositor,
    address _delegatee,
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    address _bumpCaller,
    address _tipReceiver,
    uint256 _requestedTip,
    uint256 _newEarningPower
  ) public {
    _stakeAmount = _boundToRealisticStake(_stakeAmount);
    _rewardAmount = _boundToRealisticReward(_rewardAmount);

    // A user deposits staking tokens
    (, GovernanceStaker.DepositIdentifier _depositId) =
      _boundMintAndStake(_depositor, _stakeAmount, _delegatee);
    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);
    // The full duration passes
    _jumpAheadByPercentOfRewardDuration(101);
    // Tip must be greater than the max bump
    _requestedTip = bound(_requestedTip, maxBumpTip + 1, type(uint256).max);

    // The staker's earning power changes
    earningPowerCalculator.__setEarningPowerForDelegatee(_delegatee, _newEarningPower);
    // Bump earning power is called
    vm.expectRevert(GovernanceStaker.GovernanceStaker__InvalidTip.selector);
    vm.prank(_bumpCaller);
    govStaker.bumpEarningPower(_depositId, _tipReceiver, _requestedTip);
  }

  function testFuzz_RevertIf_IsNotAQualifiedEarningPowerUpdate(
    address _depositor,
    address _delegatee,
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    address _bumpCaller,
    address _tipReceiver,
    uint256 _requestedTip,
    uint256 _newEarningPower
  ) public {
    _stakeAmount = _boundToRealisticStake(_stakeAmount);
    _rewardAmount = _boundToRealisticReward(_rewardAmount);

    // A user deposits staking tokens
    (, GovernanceStaker.DepositIdentifier _depositId) =
      _boundMintAndStake(_depositor, _stakeAmount, _delegatee);
    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);
    // The full duration passes
    _jumpAheadByPercentOfRewardDuration(101);
    // Tip must be less than the max bump
    _requestedTip = bound(_requestedTip, 0, maxBumpTip);

    // The staker's earning power changes
    earningPowerCalculator.__setEarningPowerAndIsQualifiedForDelegatee(
      _delegatee, _newEarningPower, false
    );
    // Bump earning power is called
    vm.expectRevert(
      abi.encodeWithSelector(
        GovernanceStaker.GovernanceStaker__Unqualified.selector, _newEarningPower
      )
    );
    vm.prank(_bumpCaller);
    govStaker.bumpEarningPower(_depositId, _tipReceiver, _requestedTip);
  }

  function testFuzz_RevertIf_NewEarningPowerIsTheCurrentEarningPower(
    address _depositor,
    address _delegatee,
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    address _bumpCaller,
    address _tipReceiver,
    uint256 _requestedTip
  ) public {
    _stakeAmount = _boundToRealisticStake(_stakeAmount);
    _rewardAmount = _boundToRealisticReward(_rewardAmount);

    // A user deposits staking tokens
    (, GovernanceStaker.DepositIdentifier _depositId) =
      _boundMintAndStake(_depositor, _stakeAmount, _delegatee);
    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);
    // The full duration passes
    _jumpAheadByPercentOfRewardDuration(101);
    // Tip must be less than the max bump
    _requestedTip = bound(_requestedTip, 0, maxBumpTip);

    // The staker's earning power changes
    earningPowerCalculator.__setEarningPowerForDelegatee(_delegatee, _stakeAmount);
    // Bump earning power is called
    vm.expectRevert(
      abi.encodeWithSelector(GovernanceStaker.GovernanceStaker__Unqualified.selector, _stakeAmount)
    );
    vm.prank(_bumpCaller);
    govStaker.bumpEarningPower(_depositId, _tipReceiver, _requestedTip);
  }

  function testFuzz_RevertIf_UnclaimedRewardsAreLessThanTheRequestedTipWhenEarningPowerIsBeingBumpedUp(
    address _depositor,
    address _delegatee,
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    address _bumpCaller,
    address _tipReceiver,
    uint256 _requestedTip,
    uint256 _earningPowerIncrease
  ) public {
    _stakeAmount = _boundToRealisticStake(_stakeAmount);
    _earningPowerIncrease = _boundToRealisticStake(_earningPowerIncrease);
    _rewardAmount = bound(_rewardAmount, 200e6, maxBumpTip - 1);

    // A user deposits staking tokens
    (, GovernanceStaker.DepositIdentifier _depositId) =
      _boundMintAndStake(_depositor, _stakeAmount, _delegatee);
    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);
    // The full duration passes
    _jumpAheadByPercentOfRewardDuration(101);
    vm.prank(_depositor);
    _requestedTip = bound(_requestedTip, govStaker.unclaimedReward(_depositId) + 1, maxBumpTip);

    // The staker's earning power increases
    earningPowerCalculator.__setEarningPowerForDelegatee(
      _delegatee, _stakeAmount + _earningPowerIncrease
    );
    // // Bump earning power is called
    vm.expectRevert(GovernanceStaker.GovernanceStaker__InsufficientUnclaimedRewards.selector);
    vm.prank(_bumpCaller);
    govStaker.bumpEarningPower(_depositId, _tipReceiver, _requestedTip);
  }

  function testFuzz_RevertIf_UnclaimedRewardsAreInsufficientToLeaveAnAdditionalMaxBumpTipWhenEarningPowerIsBeingBumpedDown(
    address _depositor,
    address _delegatee,
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    address _bumpCaller,
    address _tipReceiver,
    uint256 _requestedTip,
    uint256 _earningPowerDecrease
  ) public {
    vm.assume(_tipReceiver != address(0));
    _stakeAmount = _boundToRealisticStake(_stakeAmount);
    _rewardAmount = bound(_rewardAmount, 200e6, maxBumpTip - 1);
    _earningPowerDecrease = bound(_earningPowerDecrease, 1, _stakeAmount);

    // A user deposits staking tokens
    (, GovernanceStaker.DepositIdentifier _depositId) =
      _boundMintAndStake(_depositor, _stakeAmount, _delegatee);
    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);
    // The full duration passes
    _jumpAheadByPercentOfRewardDuration(101);
    // Tip must be less than the unclaimed reward
    _requestedTip = bound(_requestedTip, 0, govStaker.unclaimedReward(_depositId));

    // The staker's earning power decreases
    earningPowerCalculator.__setEarningPowerForDelegatee(
      _delegatee, _stakeAmount - _earningPowerDecrease
    );
    // Bump earning power is called
    vm.expectRevert(GovernanceStaker.GovernanceStaker__InsufficientUnclaimedRewards.selector);
    vm.prank(_bumpCaller);
    govStaker.bumpEarningPower(_depositId, _tipReceiver, _requestedTip);
  }

  function testFuzz_RevertIf_UnclaimedRewardsAreLessThanTheRequestedTipWhenEarningPowerIsBeingBumpedDown(
    address _depositor,
    address _delegatee,
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    address _bumpCaller,
    address _tipReceiver,
    uint256 _requestedTip,
    uint256 _earningPowerDecrease
  ) public {
    vm.assume(_tipReceiver != address(0));
    _stakeAmount = _boundToRealisticStake(_stakeAmount);
    _rewardAmount = bound(_rewardAmount, 200e6, maxBumpTip);
    _earningPowerDecrease = bound(_earningPowerDecrease, 1, _stakeAmount);

    // A user deposits staking tokens
    (, GovernanceStaker.DepositIdentifier _depositId) =
      _boundMintAndStake(_depositor, _stakeAmount, _delegatee);
    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);
    // The full duration passes
    _jumpAheadByPercentOfRewardDuration(101);
    _requestedTip = bound(_requestedTip, govStaker.unclaimedReward(_depositId) + 1, maxBumpTip);

    // The staker's earning power decreases
    earningPowerCalculator.__setEarningPowerForDelegatee(
      _delegatee, _stakeAmount - _earningPowerDecrease
    );
    // Bump earning power is called
    vm.prank(_bumpCaller);
    vm.expectRevert(stdError.arithmeticError);
    govStaker.bumpEarningPower(_depositId, _tipReceiver, _requestedTip);
  }

  function testFuzz_EarningPowerChangesAfterMultiplierUpdate(
    address _depositor,
    uint256 _stakeAmount,
    uint256 _multiplierBips,
    uint256 _rewardAmount
  ) public {
    vm.assume(_depositor != address(0));
    _stakeAmount = _boundToRealisticStake(_stakeAmount);
    _multiplierBips = bound(_multiplierBips, 1, 20_000);
    _rewardAmount = bound(_rewardAmount, 1000e18, 10_000_000e18);
    vm.assume(_multiplierBips != 10_000);

    // Set up the governance staker with a default multiplier
    earningPowerCalculator.__setMultiplierBips(10_000);

    vm.prank(admin);
    govStaker.setRewardNotifier(rewardNotifier, true);

    (, GovernanceStaker.DepositIdentifier depositId) =
      _boundMintAndStake(_depositor, _stakeAmount, _depositor);

    _mintTransferAndNotifyReward(_rewardAmount);

    _jumpAhead(1 days);

    // Update multiplier and bump earning power
    earningPowerCalculator.__setMultiplierBips(_multiplierBips);
    vm.prank(_depositor);
    govStaker.bumpEarningPower(depositId, _depositor, 0);

    // Verify the earning power update
    (,, uint96 actualEarningPower,,,,) = govStaker.deposits(depositId);
    uint256 expectedEarningPower = (_stakeAmount * _multiplierBips) / 10_000;
    assertEq(actualEarningPower, expectedEarningPower, "Earning power should be updated");
  }
}

contract LastTimeRewardDistributed is GovernanceStakerRewardsTest {
  function test_ReturnsZeroBeforeARewardNotificationHasOccurred() public view {
    assertEq(govStaker.lastTimeRewardDistributed(), 0);
  }

  function testFuzz_ReturnsTheBlockTimestampAfterARewardNotificationButBeforeTheRewardDurationElapses(
    uint256 _amount,
    uint256 _durationPercent
  ) public {
    _amount = _boundToRealisticReward(_amount);
    _mintTransferAndNotifyReward(_amount);

    _durationPercent = bound(_durationPercent, 0, 100);
    _jumpAheadByPercentOfRewardDuration(_durationPercent);

    assertEq(govStaker.lastTimeRewardDistributed(), block.timestamp);
  }

  function testFuzz_ReturnsTheEndOfTheRewardDurationIfItHasFullyElapsed(
    uint256 _amount,
    uint256 _durationPercent
  ) public {
    _amount = _boundToRealisticReward(_amount);
    _mintTransferAndNotifyReward(_amount);

    uint256 _durationEnd = block.timestamp + govStaker.REWARD_DURATION();

    _durationPercent = bound(_durationPercent, 101, 1000);
    _jumpAheadByPercentOfRewardDuration(_durationPercent);

    assertEq(govStaker.lastTimeRewardDistributed(), _durationEnd);
  }

  function testFuzz_ReturnsTheBlockTimestampWhileWithinTheDurationOfASecondReward(
    uint256 _amount,
    uint256 _durationPercent1,
    uint256 _durationPercent2
  ) public {
    _amount = _boundToRealisticReward(_amount);
    // Notification of first reward
    _mintTransferAndNotifyReward(_amount);

    // Some time elapses, which could be more or less than the duration
    _durationPercent1 = bound(_durationPercent1, 0, 200);
    _jumpAheadByPercentOfRewardDuration(_durationPercent1);

    // Notification of the second reward
    _mintTransferAndNotifyReward(_amount);

    // Some more time elapses, this time no more than the duration
    _durationPercent2 = bound(_durationPercent2, 0, 100);
    _jumpAheadByPercentOfRewardDuration(_durationPercent2);

    assertEq(govStaker.lastTimeRewardDistributed(), block.timestamp);
  }

  function testFuzz_ReturnsTheEndOfTheSecondRewardDurationAfterTwoRewards(
    uint256 _amount,
    uint256 _durationPercent1,
    uint256 _durationPercent2
  ) public {
    _amount = _boundToRealisticReward(_amount);
    // Notification of first reward
    _mintTransferAndNotifyReward(_amount);

    // Some time elapses, which could be more or less than the duration
    _durationPercent1 = bound(_durationPercent1, 0, 200);
    _jumpAheadByPercentOfRewardDuration(_durationPercent1);

    // Notification of the second reward
    _mintTransferAndNotifyReward(_amount);
    uint256 _durationEnd = block.timestamp + govStaker.REWARD_DURATION();

    // Some more time elapses, placing us beyond the duration of the second reward
    _durationPercent2 = bound(_durationPercent2, 101, 1000);
    _jumpAheadByPercentOfRewardDuration(_durationPercent2);

    assertEq(govStaker.lastTimeRewardDistributed(), _durationEnd);
  }
}

contract RewardPerTokenAccumulated is GovernanceStakerRewardsTest {
  function testFuzz_ReturnsZeroIfThereHasNeverBeenAReward(
    address _depositor1,
    address _depositor2,
    uint256 _stakeAmount1,
    uint256 _stakeAmount2,
    uint256 _withdrawAmount,
    uint256 _stakeMoreAmount,
    uint256 _durationPercent1
  ) public {
    // We'll perform a few arbitrary actions, such as staking, withdrawing, and staking more.
    // No matter these actions, the reward per token should always be zero since there has never
    // been the notification of a reward.

    // Derive and bound the values we'll use for jumping ahead in time
    uint256 _durationPercent2 = uint256(keccak256(abi.encode(_durationPercent1)));
    uint256 _durationPercent3 = uint256(keccak256(abi.encode(_durationPercent2)));
    _durationPercent1 = bound(_durationPercent1, 0, 200);
    _durationPercent2 = bound(_durationPercent2, 0, 200);
    _durationPercent3 = bound(_durationPercent3, 0, 200);

    // First deposit
    GovernanceStaker.DepositIdentifier _depositId1;
    (_stakeAmount1, _depositId1) = _boundMintAndStake(_depositor1, _stakeAmount1, _depositor1);
    _jumpAheadByPercentOfRewardDuration(_durationPercent1);

    // Second deposit
    (, GovernanceStaker.DepositIdentifier _depositId2) =
      _boundMintAndStake(_depositor2, _stakeAmount2, _depositor2);
    _jumpAheadByPercentOfRewardDuration(_durationPercent2);

    // First depositor withdraws some stake
    _withdrawAmount = bound(_withdrawAmount, 0, _stakeAmount1);
    vm.prank(_depositor1);
    govStaker.withdraw(_depositId1, _withdrawAmount);
    _jumpAheadByPercentOfRewardDuration(_durationPercent3);

    // Second depositor adds some stake
    _stakeMoreAmount = _boundToRealisticStake(_stakeMoreAmount);
    govToken.mint(_depositor2, _stakeMoreAmount);
    vm.startPrank(_depositor2);
    govToken.approve(address(govStaker), _stakeMoreAmount);
    govStaker.stakeMore(_depositId2, _stakeMoreAmount);
    vm.stopPrank();

    // Reward per token is still just 0
    assertEq(govStaker.rewardPerTokenAccumulated(), 0);
  }

  function testFuzz_DoesNotChangeWhileNoTokensAreStaked(
    address _depositor,
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    uint256 _durationPercent1,
    uint256 _durationPercent2,
    uint256 _durationPercent3
  ) public {
    (_stakeAmount, _rewardAmount) = _boundToRealisticStakeAndReward(_stakeAmount, _rewardAmount);
    _durationPercent1 = _bound(_durationPercent1, 0, 100);
    _durationPercent2 = _bound(_durationPercent2, 0, 200);
    _durationPercent3 = _bound(_durationPercent3, 0, 200);

    // A user deposits staking tokens
    (, GovernanceStaker.DepositIdentifier _depositId) =
      _boundMintAndStake(_depositor, _stakeAmount, _depositor);
    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);
    // Some time less than the full duration passes
    _jumpAheadByPercentOfRewardDuration(_durationPercent1);
    // We archive the value here before withdrawing the stake
    uint256 _valueBeforeStakeIsWithdrawn = govStaker.rewardPerTokenAccumulated();
    // All of the stake is withdrawn
    vm.prank(_depositor);
    govStaker.withdraw(_depositId, _stakeAmount);
    require(govStaker.totalStaked() == 0, "Test Invariant violated: expected 0 stake");
    // Some additional time passes
    _jumpAheadByPercentOfRewardDuration(_durationPercent2);
    // The contract is notified of another reward
    _mintTransferAndNotifyReward(_rewardAmount);
    // Even more time passes
    _jumpAheadByPercentOfRewardDuration(_durationPercent2);

    // The value should not have changed since the amount staked became zero
    assertEq(govStaker.rewardPerTokenAccumulated(), _valueBeforeStakeIsWithdrawn);
  }

  function testFuzz_DoesNotChangeWhileNoRewardsAreBeingDistributed(
    address _depositor,
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    uint256 _withdrawAmount,
    uint256 _durationPercent1,
    uint256 _durationPercent2,
    uint256 _durationPercent3
  ) public {
    (_stakeAmount, _rewardAmount) = _boundToRealisticStakeAndReward(_stakeAmount, _rewardAmount);
    _withdrawAmount = _bound(_withdrawAmount, 0, _stakeAmount);
    _durationPercent1 = _bound(_durationPercent1, 0, 200);
    _durationPercent2 = _bound(_durationPercent2, 0, 200);
    _durationPercent3 = _bound(_durationPercent3, 0, 200);

    // A user deposits staking tokens
    (, GovernanceStaker.DepositIdentifier _depositId) =
      _boundMintAndStake(_depositor, _stakeAmount, _depositor);
    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);
    // The full duration of the reward notification passes, meaning all rewards have dripped out
    _jumpAheadByPercentOfRewardDuration(101);
    // We archive the value here before anything else happens
    uint256 _valueAfterRewardDurationCompletes = govStaker.rewardPerTokenAccumulated();
    // Some additional time elapses
    _jumpAheadByPercentOfRewardDuration(_durationPercent1);
    // Some amount of the stake is withdrawn
    vm.prank(_depositor);
    govStaker.withdraw(_depositId, _withdrawAmount);
    // Some additional time elapses
    _jumpAheadByPercentOfRewardDuration(_durationPercent1);
    // The user makes another deposit
    _boundMintAndStake(_depositor, _stakeAmount, _depositor);
    // Even more time passes
    _jumpAheadByPercentOfRewardDuration(_durationPercent3);

    // The value should not have changed since the rewards stopped dripping out
    assertEq(govStaker.rewardPerTokenAccumulated(), _valueAfterRewardDurationCompletes);
  }

  function testFuzz_DoesNotChangeIfTimeDoesNotElapse(
    address _depositor,
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    uint256 _withdrawAmount,
    uint256 _durationPercent1
  ) public {
    (_stakeAmount, _rewardAmount) = _boundToRealisticStakeAndReward(_stakeAmount, _rewardAmount);
    _withdrawAmount = _bound(_withdrawAmount, 0, _stakeAmount);
    _durationPercent1 = _bound(_durationPercent1, 0, 200);

    // A user deposits staking tokens
    (, GovernanceStaker.DepositIdentifier _depositId) =
      _boundMintAndStake(_depositor, _stakeAmount, _depositor);
    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);
    // Some amount of time elapses
    _jumpAheadByPercentOfRewardDuration(_durationPercent1);
    // We archive the value here before anything else happens
    uint256 _valueAfterTimeElapses = govStaker.rewardPerTokenAccumulated();
    // Some amount of the stake is withdrawn
    vm.prank(_depositor);
    govStaker.withdraw(_depositId, _withdrawAmount);
    // The contract is notified of another reward
    _mintTransferAndNotifyReward(_rewardAmount);
    // The user makes another deposit
    _boundMintAndStake(_depositor, _stakeAmount, _depositor);

    // The value should not have changed since no additional time has elapsed
    assertEq(govStaker.rewardPerTokenAccumulated(), _valueAfterTimeElapses);
  }

  function testFuzz_AccruesTheCorrectValueWhenADepositorStakesForSomePortionOfAReward(
    address _depositor,
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    uint256 _durationPercent
  ) public {
    (_stakeAmount, _rewardAmount) = _boundToRealisticStakeAndReward(_stakeAmount, _rewardAmount);
    _durationPercent = _bound(_durationPercent, 0, 100);

    // A user deposits staking tokens
    _boundMintAndStake(_depositor, _stakeAmount, _depositor);
    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);
    // Some time less than the full duration passes
    _jumpAheadByPercentOfRewardDuration(_durationPercent);

    // The reward per token is the reward by the stake amount proportional to the elapsed time
    uint256 _expected = _percentOf(_scaledDiv(_rewardAmount, _stakeAmount), _durationPercent);
    assertLteWithinOnePercent(govStaker.rewardPerTokenAccumulated(), _expected);
  }

  function testFuzz_AccruesTheCorrectValueWhenADepositorStakesAfterAReward(
    address _depositor,
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    uint256 _durationPercent
  ) public {
    (_stakeAmount, _rewardAmount) = _boundToRealisticStakeAndReward(_stakeAmount, _rewardAmount);
    _durationPercent = _bound(_durationPercent, 0, 100);

    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);
    // Some time less than the full duration passes
    _jumpAheadByPercentOfRewardDuration(_durationPercent);
    // A user deposits staking tokens
    _boundMintAndStake(_depositor, _stakeAmount, _depositor);
    // The rest of the duration passes
    _jumpAheadByPercentOfRewardDuration(100 - _durationPercent);

    // The reward per token is the reward by the stake amount proportional to the elapsed time
    uint256 _expected = _percentOf(_scaledDiv(_rewardAmount, _stakeAmount), 100 - _durationPercent);
    assertLteWithinOnePercent(govStaker.rewardPerTokenAccumulated(), _expected);
  }

  function testFuzz_AccruesTheCorrectValueWhenADepositorStakesForARewardDurationAndAnotherDepositorStakesForASecondRewardDuration(
    address _depositor,
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    uint256 _durationPercent
  ) public {
    (_stakeAmount, _rewardAmount) = _boundToRealisticStakeAndReward(_stakeAmount, _rewardAmount);
    _durationPercent = _bound(_durationPercent, 100, 1000);

    // A user deposits staking tokens
    _boundMintAndStake(_depositor, _stakeAmount, _depositor);
    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);
    // The full duration passes
    _jumpAheadByPercentOfRewardDuration(_durationPercent);
    // The amount of stake exactly doubles
    _boundMintAndStake(_depositor, _stakeAmount, _depositor);
    // The contract is notified of another reward of the same size
    _mintTransferAndNotifyReward(_rewardAmount);
    // The full duration passes for the second reward
    _jumpAheadByPercentOfRewardDuration(_durationPercent);

    // We expect the sum of the reward over the stake, plus the reward over twice the stake
    uint256 _expected =
      _scaledDiv(_rewardAmount, _stakeAmount) + _scaledDiv(_rewardAmount, 2 * _stakeAmount);
    assertLteWithinOnePercent(govStaker.rewardPerTokenAccumulated(), _expected);
  }

  function testFuzz_AccruesTheCorrectValueWhenTwoDepositorsStakeAtDifferentTimesAndThereAreTwoRewards(
    address _depositor,
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    uint256 _durationPercent1,
    uint256 _durationPercent2
  ) public {
    (_stakeAmount, _rewardAmount) = _boundToRealisticStakeAndReward(_stakeAmount, _rewardAmount);
    _durationPercent1 = _bound(_durationPercent1, 0, 100);
    _durationPercent2 = _bound(_durationPercent2, 0, 100);

    // A user deposits staking tokens
    _boundMintAndStake(_depositor, _stakeAmount, _depositor);
    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);
    // Part of the reward duration passes
    _jumpAheadByPercentOfRewardDuration(_durationPercent1);
    // The amount of stake exactly doubles
    _boundMintAndStake(_depositor, _stakeAmount, _depositor);
    // The contract is notified of another reward of the same size
    _mintTransferAndNotifyReward(_rewardAmount);
    // Some additional time elapses which is less than the total duration
    _jumpAheadByPercentOfRewardDuration(_durationPercent2);

    // During the first period, the value accrued is equal to to reward amount over the stake amount
    // proportional to the time elapsed
    uint256 _expectedDuration1 =
      _percentOf(_scaledDiv(_rewardAmount, _stakeAmount), _durationPercent1);
    // After the first period, some amount of the first reward remains to be distributed
    uint256 _firstRewardRemainingAmount = _percentOf(_rewardAmount, 100 - _durationPercent1);
    // During the second period, the remaining reward plus the next reward must be divided by the
    // new staked total (2x)
    uint256 _expectedDuration2 = _percentOf(
      _scaledDiv(_firstRewardRemainingAmount + _rewardAmount, 2 * _stakeAmount), _durationPercent2
    );
    // The total expected value is the sum of the value accrued during these two periods
    uint256 _expected = _expectedDuration1 + _expectedDuration2;
    assertLteWithinOnePercent(govStaker.rewardPerTokenAccumulated(), _expected);
  }

  function testFuzz_AccruesTheCorrectValueWhenADepositorStakesAndWithdrawsDuringARewardDuration(
    address _depositor,
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    uint256 _withdrawalAmount,
    uint256 _durationPercent1,
    uint256 _durationPercent2
  ) public {
    (_stakeAmount, _rewardAmount) = _boundToRealisticStakeAndReward(_stakeAmount, _rewardAmount);
    _withdrawalAmount = _bound(_withdrawalAmount, 0, _stakeAmount - 1);
    _durationPercent1 = _bound(_durationPercent1, 0, 100);
    _durationPercent2 = _bound(_durationPercent2, 0, 100 - _durationPercent1);

    GovernanceStaker.DepositIdentifier _depositId;

    // A user deposits staking tokens
    (, _depositId) = _boundMintAndStake(_depositor, _stakeAmount, _depositor);
    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);
    // Part of the reward duration passes
    _jumpAheadByPercentOfRewardDuration(_durationPercent1);
    // Some of the stake is withdrawn
    vm.prank(_depositor);
    govStaker.withdraw(_depositId, _withdrawalAmount);
    // More of the duration elapses
    _jumpAheadByPercentOfRewardDuration(_durationPercent2);

    uint256 _expectedDuration1 =
      _percentOf(_scaledDiv(_rewardAmount, _stakeAmount), _durationPercent1);
    uint256 _expectedDuration2 =
      _percentOf(_scaledDiv(_rewardAmount, _stakeAmount - _withdrawalAmount), _durationPercent2);
    uint256 _expected = _expectedDuration1 + _expectedDuration2;
    assertLteWithinOnePercent(govStaker.rewardPerTokenAccumulated(), _expected);
  }

  function testFuzz_AccruesTheCorrectValueWhenTwoDepositorsStakeDifferentAmountsAtDifferentTimesOverTwoRewards(
    address _depositor1,
    address _depositor2,
    uint256 _stakeAmount1,
    uint256 _stakeAmount2,
    uint256 _rewardAmount,
    uint256 _durationPercent1,
    uint256 _durationPercent2,
    uint256 _durationPercent3
  ) public {
    _stakeAmount1 = _boundToRealisticStake(_stakeAmount1);
    _stakeAmount2 = _boundToRealisticStake(_stakeAmount2);
    _rewardAmount = _boundToRealisticReward(_rewardAmount);
    _durationPercent1 = _bound(_durationPercent1, 0, 100);
    _durationPercent2 = _bound(_durationPercent2, 0, 100);
    _durationPercent3 = _bound(_durationPercent2, 0, 100 - _durationPercent2);

    // A user deposits staking tokens
    _boundMintAndStake(_depositor1, _stakeAmount1, _depositor1);
    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);
    // Part of the reward duration passes
    _jumpAheadByPercentOfRewardDuration(_durationPercent1);
    // The contract is notified of another reward, resetting the duration
    _mintTransferAndNotifyReward(_rewardAmount);
    // Part of the new reward duration passes
    _jumpAheadByPercentOfRewardDuration(_durationPercent2);
    // Another user deposits a different number of staking tokens
    _boundMintAndStake(_depositor2, _stakeAmount2, _depositor2);
    // More of the reward duration passes
    _jumpAheadByPercentOfRewardDuration(_durationPercent3);

    // During the first time period, the expected value is the reward amount over the staked amount,
    // proportional to the time elapsed
    uint256 _expectedDuration1 =
      _percentOf(_scaledDiv(_rewardAmount, _stakeAmount1), _durationPercent1);
    // The rewards after the second notification are the remaining rewards plus the new rewards.
    // We scale them up here to avoid losing precision in our expectation estimates.
    uint256 _scaledRewardsAfterDuration1 = (
      SCALE_FACTOR * _rewardAmount - _percentOf(SCALE_FACTOR * _rewardAmount, _durationPercent1)
    ) + SCALE_FACTOR * _rewardAmount;
    // During the second time period, the expected value is the new reward amount over the staked
    // amount, proportional to the time elapsed
    uint256 _expectedDuration2 =
      _percentOf(_scaledRewardsAfterDuration1 / _stakeAmount1, _durationPercent2);
    // During the third time period, the expected value is the reward amount over the new total
    // staked amount, proportional to the time elapsed
    uint256 _expectedDuration3 =
      _percentOf(_scaledRewardsAfterDuration1 / (_stakeAmount1 + _stakeAmount2), _durationPercent3);

    uint256 _expected = _expectedDuration1 + _expectedDuration2 + _expectedDuration3;
    assertLteWithinOnePercent(govStaker.rewardPerTokenAccumulated(), _expected);
  }

  function testFuzz_AccruesTheCorrectValueWhenAnArbitraryNumberOfDepositorsStakeDifferentAmountsOverTheCourseOfARewardDuration(
    address _depositor,
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    uint256 _durationPercent
  ) public {
    _rewardAmount = _boundToRealisticReward(_rewardAmount);

    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);

    uint256 _expected;
    uint256 _totalStake;
    uint256 _totalDurationPercent;

    // Now we'll perform an arbitrary number of differently sized deposits
    while (_totalDurationPercent < 100) {
      // On each iteration we derive new values
      _depositor = address(uint160(uint256(keccak256(abi.encode(_depositor)))));
      _stakeAmount = uint256(keccak256(abi.encode(_stakeAmount)));
      _stakeAmount = _boundToRealisticStake(_stakeAmount);
      _durationPercent = uint256(keccak256(abi.encode(_durationPercent)));
      // We make sure the duration jump on each iteration isn't so small that we slow the test
      // down excessively, but also isn't so big we don't get at least a few iterations.
      _durationPercent = bound(_durationPercent, 10, 33);

      // A user deposits some staking tokens
      _boundMintAndStake(_depositor, _stakeAmount, _depositor);
      _totalStake += _stakeAmount;

      // Part of the reward duration passes
      _jumpAheadByPercentOfRewardDuration(_durationPercent);
      _totalDurationPercent += _durationPercent;

      if (_totalDurationPercent > 100) {
        // If we've jumped ahead past the end of the duration, this will be the last iteration so
        // the only portion of the time elapsed that contributed to the accrued expected value is
        // the portion before we reached 100% of the duration.
        _durationPercent = 100 - (_totalDurationPercent - _durationPercent);
      }

      // At each iteration, we recalculate and check the accruing value
      _expected += _percentOf(_scaledDiv(_rewardAmount, _totalStake), _durationPercent);
      assertLteWithinOnePercent(govStaker.rewardPerTokenAccumulated(), _expected);
    }
  }
}

contract UnclaimedReward is GovernanceStakerRewardsTest {
  function testFuzz_CalculatesCorrectEarningsForASingleDepositorThatStakesForFullDuration(
    address _depositor,
    address _delegatee,
    uint256 _stakeAmount,
    uint256 _rewardAmount
  ) public {
    (_stakeAmount, _rewardAmount) = _boundToRealisticStakeAndReward(_stakeAmount, _rewardAmount);

    // A user deposits staking tokens
    (, GovernanceStaker.DepositIdentifier _depositId) =
      _boundMintAndStake(_depositor, _stakeAmount, _delegatee);
    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);
    // The full duration passes
    _jumpAheadByPercentOfRewardDuration(101);

    // The user should have earned all the rewards
    assertLteWithinOnePercent(govStaker.unclaimedReward(_depositId), _rewardAmount);
  }

  function testFuzz_CalculatesCorrectEarningsWhenASingleDepositorAssignsAClaimerAndStakesForFullDuration(
    address _depositor,
    address _delegatee,
    address _claimer,
    uint256 _stakeAmount,
    uint256 _rewardAmount
  ) public {
    (_stakeAmount, _rewardAmount) = _boundToRealisticStakeAndReward(_stakeAmount, _rewardAmount);

    // A user deposits staking tokens w/ a claimer
    (, GovernanceStaker.DepositIdentifier _depositId) =
      _boundMintAndStake(_depositor, _stakeAmount, _delegatee, _claimer);
    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);
    // The full duration passes
    _jumpAheadByPercentOfRewardDuration(101);

    // The claimer should have earned all the rewards
    assertLteWithinOnePercent(govStaker.unclaimedReward(_depositId), _rewardAmount);
  }

  function testFuzz_CalculatesCorrectEarningsForASingleUserThatDepositsStakeForPartialDuration(
    address _depositor,
    address _delegatee,
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    uint256 _durationPercent
  ) public {
    (_stakeAmount, _rewardAmount) = _boundToRealisticStakeAndReward(_stakeAmount, _rewardAmount);
    _durationPercent = bound(_durationPercent, 0, 100);

    // A user deposits staking tokens
    (, GovernanceStaker.DepositIdentifier _depositId) =
      _boundMintAndStake(_depositor, _stakeAmount, _delegatee);
    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);
    // One third of the duration passes
    _jumpAheadByPercentOfRewardDuration(_durationPercent);

    // The user should have earned one third of the rewards
    assertLteWithinOnePercent(
      govStaker.unclaimedReward(_depositId), _percentOf(_rewardAmount, _durationPercent)
    );
  }

  function testFuzz_CalculatesCorrectEarningsForASingleUserThatDepositsPartiallyThroughTheDuration(
    address _depositor,
    address _delegatee,
    uint256 _stakeAmount,
    uint256 _rewardAmount
  ) public {
    (_stakeAmount, _rewardAmount) = _boundToRealisticStakeAndReward(_stakeAmount, _rewardAmount);

    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);
    // Two thirds of the duration time passes
    _jumpAheadByPercentOfRewardDuration(66);
    // A user deposits staking tokens
    (, GovernanceStaker.DepositIdentifier _depositId) =
      _boundMintAndStake(_depositor, _stakeAmount, _delegatee);
    // The rest of the duration elapses
    _jumpAheadByPercentOfRewardDuration(34);

    // The user should have earned 1/3rd of the rewards
    assertLteWithinOnePercent(govStaker.unclaimedReward(_depositId), _percentOf(_rewardAmount, 34));
  }

  function testFuzz_CalculatesCorrectEarningsForASingleUserThatDepositsStakeForTheFullDurationWithNoNewRewards(
    address _depositor,
    address _delegatee,
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    uint16 _noRewardsSkip
  ) public {
    (_stakeAmount, _rewardAmount) = _boundToRealisticStakeAndReward(_stakeAmount, _rewardAmount);

    // A user deposits staking tokens
    (, GovernanceStaker.DepositIdentifier _depositId) =
      _boundMintAndStake(_depositor, _stakeAmount, _delegatee);
    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);

    // The full duration passes
    _jumpAheadByPercentOfRewardDuration(100);
    // Time moves forward with no rewards
    _jumpAheadByPercentOfRewardDuration(_noRewardsSkip);

    // Send new rewards, which should have no impact on the amount earned until time elapses
    _mintTransferAndNotifyReward(_rewardAmount);

    // The user should have earned all the rewards
    assertLteWithinOnePercent(govStaker.unclaimedReward(_depositId), _rewardAmount);
  }

  function testFuzz_CalculatesCorrectEarningsForASingleUserThatDepositsStakeForTheFullDurationAndClaims(
    address _depositor,
    address _delegatee,
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    uint256 _durationPercent
  ) public {
    vm.assume(_depositor != address(govStaker));
    (_stakeAmount, _rewardAmount) = _boundToRealisticStakeAndReward(_stakeAmount, _rewardAmount);
    _durationPercent = bound(_durationPercent, 0, 100);

    // A user deposits staking tokens
    (, GovernanceStaker.DepositIdentifier _depositId) =
      _boundMintAndStake(_depositor, _stakeAmount, _delegatee);
    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);

    // The full duration passes
    _jumpAheadByPercentOfRewardDuration(101);

    // The depositor claims the rewards
    vm.prank(_depositor);
    govStaker.claimReward(_depositId);

    // Send new rewards
    _mintTransferAndNotifyReward(_rewardAmount);
    _jumpAheadByPercentOfRewardDuration(_durationPercent);

    uint256 balance = govStaker.REWARD_TOKEN().balanceOf(address(_depositor));

    // The depositors balance should reflect the first full duration
    assertLteWithinOnePercent(balance, _rewardAmount);
    // The depositor should have earned a portion of the rewards equal to the amount of the next
    // duration that has passed.
    assertLteWithinOnePercent(
      govStaker.unclaimedReward(_depositId), _percentOf(_rewardAmount, _durationPercent)
    );
  }

  function testFuzz_CalculatesCorrectEarningsForASingleUserThatDepositsStakeForThePartialDurationAndClaims(
    address _depositor,
    address _delegatee,
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    uint256 _durationPercent
  ) public {
    vm.assume(_depositor != address(govStaker));
    (_stakeAmount, _rewardAmount) = _boundToRealisticStakeAndReward(_stakeAmount, _rewardAmount);
    _durationPercent = bound(_durationPercent, 0, 100);

    // A user deposits staking tokens
    (, GovernanceStaker.DepositIdentifier _depositId) =
      _boundMintAndStake(_depositor, _stakeAmount, _delegatee);
    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);

    // The full duration passes
    _jumpAheadByPercentOfRewardDuration(_durationPercent);

    // The depositor claims the reward
    vm.prank(_depositor);
    govStaker.claimReward(_depositId);

    // We skip ahead to the end of the duration
    _jumpAheadByPercentOfRewardDuration(100 - _durationPercent);

    uint256 balance = govStaker.REWARD_TOKEN().balanceOf(address(_depositor));

    // The depositors balance should match the portion of the duration that passed before the
    // rewards were claimed
    assertLteWithinOnePercent(balance, _percentOf(_rewardAmount, _durationPercent));
    // The depositor earned the portion of the reward after the rewards were claimed
    assertLteWithinOnePercent(
      govStaker.unclaimedReward(_depositId), _percentOf(_rewardAmount, 100 - _durationPercent)
    );
  }

  function testFuzz_CalculatesCorrectEarningsForTwoUsersThatDepositEqualStakeForFullDuration(
    address _depositor1,
    address _depositor2,
    address _delegatee,
    uint256 _stakeAmount,
    uint256 _rewardAmount
  ) public {
    vm.assume(_depositor1 != _depositor2);
    (_stakeAmount, _rewardAmount) = _boundToRealisticStakeAndReward(_stakeAmount, _rewardAmount);

    // A user deposits staking tokens
    (, GovernanceStaker.DepositIdentifier _depositId1) =
      _boundMintAndStake(_depositor1, _stakeAmount, _delegatee);
    // Some time passes
    _jumpAhead(3000);
    // Another depositor deposits the same number of staking tokens
    (, GovernanceStaker.DepositIdentifier _depositId2) =
      _boundMintAndStake(_depositor2, _stakeAmount, _delegatee);
    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);
    // The full duration passes
    _jumpAheadByPercentOfRewardDuration(101);

    // Each user should have earned half of the rewards
    assertLteWithinOnePercent(govStaker.unclaimedReward(_depositId1), _percentOf(_rewardAmount, 50));
    assertLteWithinOnePercent(govStaker.unclaimedReward(_depositId2), _percentOf(_rewardAmount, 50));
  }

  function testFuzz_CalculatesCorrectEarningsForTwoUsersWhenOneStakesMorePartiallyThroughTheDuration(
    address _depositor1,
    address _depositor2,
    address _delegatee,
    uint256 _stakeAmount,
    uint256 _rewardAmount
  ) public {
    vm.assume(_depositor1 != _depositor2);
    (_stakeAmount, _rewardAmount) = _boundToRealisticStakeAndReward(_stakeAmount, _rewardAmount);

    // A user deposits staking tokens
    (, GovernanceStaker.DepositIdentifier _depositId1) =
      _boundMintAndStake(_depositor1, _stakeAmount, _delegatee);
    // Some time passes
    _jumpAhead(3000);
    // Another depositor deposits the same number of staking tokens
    (, GovernanceStaker.DepositIdentifier _depositId2) =
      _boundMintAndStake(_depositor2, _stakeAmount, _delegatee);
    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);
    // One third of the duration passes
    _jumpAheadByPercentOfRewardDuration(34);
    // The first user triples their deposit by staking 2x more
    _mintGovToken(_depositor1, 2 * _stakeAmount);
    vm.startPrank(_depositor1);
    govToken.approve(address(govStaker), 2 * _stakeAmount);
    govStaker.stakeMore(_depositId1, 2 * _stakeAmount);
    vm.stopPrank();
    // The rest of the duration passes
    _jumpAheadByPercentOfRewardDuration(66);

    // Depositor 1 earns half the reward for one third the time and three quarters for two thirds of
    // the time
    uint256 _depositor1ExpectedEarnings =
      _percentOf(_percentOf(_rewardAmount, 50), 34) + _percentOf(_percentOf(_rewardAmount, 75), 66);
    // Depositor 2 earns half the reward for one third the time and one quarter for two thirds of
    // the time
    uint256 _depositor2ExpectedEarnings =
      _percentOf(_percentOf(_rewardAmount, 50), 34) + _percentOf(_percentOf(_rewardAmount, 25), 66);

    // Each user should have earned half of the rewards
    assertLteWithinOnePercent(govStaker.unclaimedReward(_depositId1), _depositor1ExpectedEarnings);
    assertLteWithinOnePercent(govStaker.unclaimedReward(_depositId2), _depositor2ExpectedEarnings);
  }

  function testFuzz_CalculatesCorrectEarningsForTwoUsersThatDepositEqualStakeForFullDurationAndBothClaim(
    address _depositor1,
    address _depositor2,
    address _delegatee,
    uint256 _stakeAmount,
    uint256 _rewardAmount
  ) public {
    vm.assume(_depositor1 != _depositor2);
    vm.assume(_depositor1 != address(govStaker) && _depositor2 != address(govStaker));
    (_stakeAmount, _rewardAmount) = _boundToRealisticStakeAndReward(_stakeAmount, _rewardAmount);

    // A user deposits staking tokens
    (, GovernanceStaker.DepositIdentifier _depositId1) =
      _boundMintAndStake(_depositor1, _stakeAmount, _delegatee);
    // Some time passes
    _jumpAhead(3000);
    // Another depositor deposits the same number of staking tokens
    (, GovernanceStaker.DepositIdentifier _depositId2) =
      _boundMintAndStake(_depositor2, _stakeAmount, _delegatee);
    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);
    // The full duration passes
    _jumpAheadByPercentOfRewardDuration(101);

    // Depositor 1 claims
    vm.prank(_depositor1);
    govStaker.claimReward(_depositId1);

    // Depositor 2 claims
    vm.prank(_depositor2);
    govStaker.claimReward(_depositId2);

    uint256 depositor1Balance = govStaker.REWARD_TOKEN().balanceOf(address(_depositor1));
    uint256 depositor2Balance = govStaker.REWARD_TOKEN().balanceOf(address(_depositor2));

    // Each depositors balance should be half of the reward
    assertLteWithinOnePercent(depositor1Balance, _percentOf(_rewardAmount, 50));
    assertLteWithinOnePercent(depositor2Balance, _percentOf(_rewardAmount, 50));

    // Each user should have earned nothing since they both claimed their rewards
    assertLteWithinOnePercent(govStaker.unclaimedReward(_depositId1), 0);
    assertLteWithinOnePercent(govStaker.unclaimedReward(_depositId2), 0);
  }

  function testFuzz_CalculatesCorrectEarningsForTwoUsersWhenOneStakesMorePartiallyThroughTheDurationAndOneClaims(
    address _depositor1,
    address _depositor2,
    address _delegatee,
    uint256 _stakeAmount,
    uint256 _rewardAmount
  ) public {
    vm.assume(_depositor1 != _depositor2);
    vm.assume(_depositor1 != address(govStaker) && _depositor2 != address(govStaker));
    (_stakeAmount, _rewardAmount) = _boundToRealisticStakeAndReward(_stakeAmount, _rewardAmount);

    // A user deposits staking tokens
    (, GovernanceStaker.DepositIdentifier _depositId1) =
      _boundMintAndStake(_depositor1, _stakeAmount, _delegatee);
    // Some time passes
    _jumpAhead(3000);
    // Another depositor deposits the same number of staking tokens
    (, GovernanceStaker.DepositIdentifier _depositId2) =
      _boundMintAndStake(_depositor2, _stakeAmount, _delegatee);
    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);
    // One third of the duration passes
    _jumpAheadByPercentOfRewardDuration(34);
    // The first depositor claims their reward
    vm.prank(_depositor1);
    govStaker.claimReward(_depositId1);
    // The first depositor triples their deposit by staking 2x more
    _mintGovToken(_depositor1, 2 * _stakeAmount);
    vm.startPrank(_depositor1);
    govToken.approve(address(govStaker), 2 * _stakeAmount);
    govStaker.stakeMore(_depositId1, 2 * _stakeAmount);
    vm.stopPrank();
    // The rest of the duration passes
    _jumpAheadByPercentOfRewardDuration(66);

    // Depositor 1 earns three quarters of the reward for two thirds of the time
    uint256 _depositor1ExpectedEarnings = _percentOf(_percentOf(_rewardAmount, 75), 66);
    // Depositor 2 earns half the reward for one third the time and one quarter for two thirds of
    // the time
    uint256 _depositor2ExpectedEarnings =
      _percentOf(_percentOf(_rewardAmount, 50), 34) + _percentOf(_percentOf(_rewardAmount, 25), 66);

    uint256 depositor1Balance = govStaker.REWARD_TOKEN().balanceOf(address(_depositor1));
    uint256 depositor2Balance = govStaker.REWARD_TOKEN().balanceOf(address(_depositor2));

    assertLteWithinOnePercent(govStaker.unclaimedReward(_depositId1), _depositor1ExpectedEarnings);
    assertLteWithinOnePercent(govStaker.unclaimedReward(_depositId2), _depositor2ExpectedEarnings);

    // Depositor 1 should have received the reward they earned from before they claimed
    assertLteWithinOnePercent(depositor1Balance, _percentOf(_percentOf(_rewardAmount, 50), 34));
    // Depositor 2 should not have received anything because they did not claim
    assertLteWithinOnePercent(depositor2Balance, 0);
  }

  function testFuzz_CalculatesCorrectEarningsWhenAUserStakesThroughTheDurationAndAnotherStakesPartially(
    address _depositor1,
    address _depositor2,
    address _delegatee,
    uint256 _stakeAmount,
    uint256 _rewardAmount
  ) public {
    vm.assume(_depositor1 != _depositor2);
    (_stakeAmount, _rewardAmount) = _boundToRealisticStakeAndReward(_stakeAmount, _rewardAmount);

    // The first user stakes some tokens
    (, GovernanceStaker.DepositIdentifier _depositId1) =
      _boundMintAndStake(_depositor1, _stakeAmount, _delegatee);
    // A small amount of time passes
    _jumpAhead(3000);
    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);
    // Two thirds of the duration time elapses
    _jumpAheadByPercentOfRewardDuration(66);
    // A second user stakes the same amount of tokens
    (, GovernanceStaker.DepositIdentifier _depositId2) =
      _boundMintAndStake(_depositor2, _stakeAmount, _delegatee);
    // The rest of the duration elapses
    _jumpAheadByPercentOfRewardDuration(34);

    // Depositor 1 earns the full rewards for 2/3rds of the time & 1/2 the reward for 1/3rd of the
    // time
    uint256 _depositor1ExpectedEarnings =
      _percentOf(_rewardAmount, 66) + _percentOf(_percentOf(_rewardAmount, 50), 34);
    // Depositor 2 earns 1/2 the rewards for 1/3rd of the duration time
    uint256 _depositor2ExpectedEarnings = _percentOf(_percentOf(_rewardAmount, 50), 34);

    assertLteWithinOnePercent(govStaker.unclaimedReward(_depositId1), _depositor1ExpectedEarnings);
    assertLteWithinOnePercent(govStaker.unclaimedReward(_depositId2), _depositor2ExpectedEarnings);
  }

  function testFuzz_CalculatesCorrectEarningsWhenAUserDepositsAndThereAreTwoRewards(
    address _depositor,
    address _delegatee,
    uint256 _stakeAmount,
    uint256 _rewardAmount1,
    uint256 _rewardAmount2
  ) public {
    (_stakeAmount, _rewardAmount1) = _boundToRealisticStakeAndReward(_stakeAmount, _rewardAmount1);
    (_stakeAmount, _rewardAmount2) = _boundToRealisticStakeAndReward(_stakeAmount, _rewardAmount2);

    // A user stakes tokens
    (, GovernanceStaker.DepositIdentifier _depositId) =
      _boundMintAndStake(_depositor, _stakeAmount, _delegatee);
    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount1);
    // Two thirds of duration elapses
    _jumpAheadByPercentOfRewardDuration(66);
    // The contract is notified of a new reward, which restarts the reward the duration
    _mintTransferAndNotifyReward(_rewardAmount2);
    // Another third of the duration time elapses
    _jumpAheadByPercentOfRewardDuration(34);

    // For the first two thirds of the duration, the depositor earned all of the rewards being
    // dripped out. Then more rewards were distributed. This resets the period. For the next
    // period, which we chose to be another third of the duration, the depositor continued to earn
    // all of the rewards being dripped, which now comprised of the remaining third of the first
    // reward plus the second reward.
    uint256 _depositorExpectedEarnings = _percentOf(_rewardAmount1, 66)
      + _percentOf(_percentOf(_rewardAmount1, 34) + _rewardAmount2, 34);
    assertLteWithinOnePercent(govStaker.unclaimedReward(_depositId), _depositorExpectedEarnings);
  }

  function testFuzz_CalculatesCorrectEarningsWhenTwoUsersDepositForPartialDurationsAndThereAreTwoRewards(
    address _depositor1,
    address _depositor2,
    address _delegatee,
    uint256 _stakeAmount,
    uint256 _rewardAmount1,
    uint256 _rewardAmount2
  ) public {
    vm.assume(_depositor1 != _depositor2);
    (_stakeAmount, _rewardAmount1) = _boundToRealisticStakeAndReward(_stakeAmount, _rewardAmount1);
    (_stakeAmount, _rewardAmount2) = _boundToRealisticStakeAndReward(_stakeAmount, _rewardAmount2);

    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount1);
    // One quarter of the duration elapses
    _jumpAheadByPercentOfRewardDuration(25);
    // A user stakes some tokens
    (, GovernanceStaker.DepositIdentifier _depositId1) =
      _boundMintAndStake(_depositor1, _stakeAmount, _delegatee);
    // Another 40 percent of the duration time elapses
    _jumpAheadByPercentOfRewardDuration(40);
    // Another user stakes some tokens
    (, GovernanceStaker.DepositIdentifier _depositId2) =
      _boundMintAndStake(_depositor2, _stakeAmount, _delegatee);
    // Another quarter of the duration elapses
    _jumpAheadByPercentOfRewardDuration(25);
    // The contract receives another reward, resetting the duration
    _mintTransferAndNotifyReward(_rewardAmount2);
    // Another 20 percent of the duration elapses
    _jumpAheadByPercentOfRewardDuration(20);

    // The second depositor earns:
    // * Half the rewards distributed (split with depositor 1) over 1/4 of the duration, where the
    //   rewards being earned are all from the first reward notification
    // * Half the rewards (split with depositor 1) over 1/5 of the duration, where the rewards
    //   being earned are the remaining 10% of the first reward notification, plus the second
    //   reward notification
    uint256 _depositor2ExpectedEarnings = _percentOf(_percentOf(_rewardAmount1, 25), 50)
      + _percentOf(_percentOf(_percentOf(_rewardAmount1, 10) + _rewardAmount2, 20), 50);

    // The first depositor earns the same amount as the second depositor, since they had the same
    // stake and thus split the rewards during the period where both were staking. But the first
    // depositor also earned all of the rewards for 40% of the duration, where the rewards being
    // earned were from the first reward notification.
    uint256 _depositor1ExpectedEarnings =
      _percentOf(_rewardAmount1, 40) + _depositor2ExpectedEarnings;

    assertLteWithinOnePercent(govStaker.unclaimedReward(_depositId1), _depositor1ExpectedEarnings);
    assertLteWithinOnePercent(govStaker.unclaimedReward(_depositId2), _depositor2ExpectedEarnings);
  }

  function testFuzz_CalculatesCorrectEarningsWhenTwoUsersDepositDifferentAmountsForPartialDurationsAndThereAreTwoRewards(
    address _depositor1,
    address _depositor2,
    address _delegatee,
    uint256 _stakeAmount1,
    uint256 _stakeAmount2,
    uint256 _rewardAmount1,
    uint256 _rewardAmount2
  ) public {
    vm.assume(_depositor1 != _depositor2);
    (_stakeAmount1, _rewardAmount1) = _boundToRealisticStakeAndReward(_stakeAmount1, _rewardAmount1);
    (_stakeAmount2, _rewardAmount2) = _boundToRealisticStakeAndReward(_stakeAmount2, _rewardAmount2);

    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount1);
    // One quarter of the duration elapses
    _jumpAheadByPercentOfRewardDuration(25);
    // A user stakes some tokens
    (, GovernanceStaker.DepositIdentifier _depositId1) =
      _boundMintAndStake(_depositor1, _stakeAmount1, _delegatee);
    // Another 40 percent of the duration time elapses
    _jumpAheadByPercentOfRewardDuration(40);
    // Another user stakes some tokens
    (, GovernanceStaker.DepositIdentifier _depositId2) =
      _boundMintAndStake(_depositor2, _stakeAmount2, _delegatee);
    // Another quarter of the duration elapses
    _jumpAheadByPercentOfRewardDuration(25);
    // The contract receives another reward, resetting the duration
    _mintTransferAndNotifyReward(_rewardAmount2);
    // Another 20 percent of the duration elapses
    _jumpAheadByPercentOfRewardDuration(20);

    // The total staked by both depositors together
    uint256 _combinedStake = _stakeAmount1 + _stakeAmount2;
    // These are the total rewards distributed by the contract after the second depositor adds
    // their stake. It is the first reward for a quarter of the duration, plus the remaining 10% of
    // the first reward, plus the second reward, for a fifth of the duration.
    uint256 _combinedPhaseExpectedTotalRewards = _percentOf(_rewardAmount1, 25)
      + _percentOf(_percentOf(_rewardAmount1, 10) + _rewardAmount2, 20);

    // The second depositor should earn a share of the combined phase reward scaled by their
    // portion of the total stake.
    uint256 _depositor2ExpectedEarnings =
      (_stakeAmount2 * _combinedPhaseExpectedTotalRewards) / _combinedStake;

    // The first depositor earned all of the rewards for 40% of the duration, where the rewards
    // were from the first reward notification. The first depositor also earns a share of the
    // combined phase rewards proportional to his share of the stake.
    uint256 _depositor1ExpectedEarnings = _percentOf(_rewardAmount1, 40)
      + (_stakeAmount1 * _combinedPhaseExpectedTotalRewards) / _combinedStake;

    assertLteWithinOnePercent(govStaker.unclaimedReward(_depositId1), _depositor1ExpectedEarnings);
    assertLteWithinOnePercent(govStaker.unclaimedReward(_depositId2), _depositor2ExpectedEarnings);
  }

  // Could potentially add duration
  function testFuzz_CalculatesCorrectEarningsWhenAUserDepositsAndThereAreThreeRewards(
    address _depositor,
    address _delegatee,
    uint256 _stakeAmount,
    uint256 _rewardAmount1,
    uint256 _rewardAmount2,
    uint256 _rewardAmount3
  ) public {
    (_stakeAmount, _rewardAmount1) = _boundToRealisticStakeAndReward(_stakeAmount, _rewardAmount1);
    (_stakeAmount, _rewardAmount2) = _boundToRealisticStakeAndReward(_stakeAmount, _rewardAmount2);
    (_stakeAmount, _rewardAmount3) = _boundToRealisticStakeAndReward(_stakeAmount, _rewardAmount3);

    // A user stakes tokens
    (, GovernanceStaker.DepositIdentifier _depositId) =
      _boundMintAndStake(_depositor, _stakeAmount, _delegatee);
    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount1);
    // Two thirds of duration elapses
    _jumpAheadByPercentOfRewardDuration(40);
    // The contract is notified of a new reward, which restarts the reward the duration
    _mintTransferAndNotifyReward(_rewardAmount2);
    // Another third of the duration time elapses
    _jumpAheadByPercentOfRewardDuration(30);
    _mintTransferAndNotifyReward(_rewardAmount3);

    _jumpAheadByPercentOfRewardDuration(30);

    // For the first 40% of the duration, the depositor earned all of the rewards being
    // dripped out. Then more rewards were distributed. This resets the period. For the next
    // period, which we chose to be 30% of the duration, the depositor continued to earn
    // all of the rewards being dripped, which now comprised of the remaining 60% of the first
    // reward plus the second reward. For the next period, which we chose to be another 30% of the
    // duration, the depositor continued to earn the rewards of the previous period, which now
    // comprised of the remaining 70% of second period reward plus 30% of the third reward.
    uint256 _depositorExpectedEarnings = _percentOf(_rewardAmount1, 40)
      + _percentOf(_percentOf(_rewardAmount1, 60) + _rewardAmount2, 30)
      + _percentOf(
        _percentOf(_percentOf(_rewardAmount1, 60) + _rewardAmount2, 70) + _rewardAmount3, 30
      );
    assertLteWithinOnePercent(govStaker.unclaimedReward(_depositId), _depositorExpectedEarnings);
  }

  function testFuzz_CalculatesCorrectEarningsWhenTwoUsersDepositForPartialDurationsAndThereAreThreeRewards(
    address _depositor1,
    address _depositor2,
    address _delegatee,
    uint256 _stakeAmount,
    uint256 _rewardAmount1,
    uint256 _rewardAmount2,
    uint256 _rewardAmount3
  ) public {
    vm.assume(_depositor1 != _depositor2);
    (_stakeAmount, _rewardAmount1) = _boundToRealisticStakeAndReward(_stakeAmount, _rewardAmount1);
    (_stakeAmount, _rewardAmount2) = _boundToRealisticStakeAndReward(_stakeAmount, _rewardAmount2);
    (_stakeAmount, _rewardAmount3) = _boundToRealisticStakeAndReward(_stakeAmount, _rewardAmount3);

    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount1);
    // One quarter of the duration elapses
    _jumpAheadByPercentOfRewardDuration(25);
    // A user stakes some tokens
    (, GovernanceStaker.DepositIdentifier _depositId1) =
      _boundMintAndStake(_depositor1, _stakeAmount, _delegatee);
    // Another 20 percent of the duration time elapses
    _jumpAheadByPercentOfRewardDuration(20);
    // Another user stakes some tokens
    (, GovernanceStaker.DepositIdentifier _depositId2) =
      _boundMintAndStake(_depositor2, _stakeAmount, _delegatee);
    // Another 20 percent of the duration time elapses
    _jumpAheadByPercentOfRewardDuration(20);
    // The contract receives another reward, resetting the duration
    _mintTransferAndNotifyReward(_rewardAmount2);
    // Another 20 percent of the duration elapses
    _jumpAheadByPercentOfRewardDuration(20);
    // The contract receives another reward, resetting the duration
    _mintTransferAndNotifyReward(_rewardAmount3);
    // Another 20 percent of the duration elapses
    _jumpAheadByPercentOfRewardDuration(20);

    // The second depositor earns:
    // * Half the rewards distributed (split with depositor 1) over 1/5 of the duration, where the
    //   rewards being earned are all from the first reward notification
    // * Half the rewards (split with depositor 1) over 1/5 of the duration, where the rewards
    //   being earned are the remaining 35% of the first reward notification, plus 20% the second
    //   reward notification
    // * Half the rewards (split with depositor 1) over 1/5 the duration where the rewards being
    // earned
    //   are 20% of the previous reward and the third reward
    uint256 _depositor2ExpectedEarnings = _percentOf(_percentOf(_rewardAmount1, 20), 50)
      + _percentOf(_percentOf(_percentOf(_rewardAmount1, 35) + _rewardAmount2, 20), 50)
      + _percentOf(
        _percentOf(
          _percentOf(_percentOf(_rewardAmount1, 35) + _rewardAmount2, 80) + _rewardAmount3, 20
        ),
        50
      );

    // // The first depositor earns the same amount as the second depositor, since they had the same
    // // stake and thus split the rewards during the period where both were staking. But the first
    // // depositor also earned all of the rewards for 20% of the duration, where the rewards being
    // // earned were from the first reward notification.
    uint256 _depositor1ExpectedEarnings =
      _percentOf(_rewardAmount1, 20) + _depositor2ExpectedEarnings;

    assertLteWithinOnePercent(govStaker.unclaimedReward(_depositId1), _depositor1ExpectedEarnings);
    assertLteWithinOnePercent(govStaker.unclaimedReward(_depositId2), _depositor2ExpectedEarnings);
  }

  function testFuzz_CalculatesCorrectEarningsWhenTwoUsersDepositDifferentAmountsForPartialDurationsAndThereAreThreeRewards(
    address _depositor1,
    address _depositor2,
    address _delegatee,
    uint256 _stakeAmount1,
    uint256 _stakeAmount2,
    uint256 _rewardAmount1,
    uint256 _rewardAmount2,
    uint256 _rewardAmount3
  ) public {
    vm.assume(_depositor1 != _depositor2);
    (_stakeAmount1, _rewardAmount1) = _boundToRealisticStakeAndReward(_stakeAmount1, _rewardAmount1);
    (_stakeAmount2, _rewardAmount2) = _boundToRealisticStakeAndReward(_stakeAmount2, _rewardAmount2);
    (_stakeAmount2, _rewardAmount3) = _boundToRealisticStakeAndReward(_stakeAmount2, _rewardAmount3);

    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount1);
    // One quarter of the duration elapses
    _jumpAheadByPercentOfRewardDuration(25);
    // A user stakes some tokens
    (, GovernanceStaker.DepositIdentifier _depositId1) =
      _boundMintAndStake(_depositor1, _stakeAmount1, _delegatee);
    // Another 40 percent of the duration time elapses
    _jumpAheadByPercentOfRewardDuration(20);
    // Another user stakes some tokens
    (, GovernanceStaker.DepositIdentifier _depositId2) =
      _boundMintAndStake(_depositor2, _stakeAmount2, _delegatee);
    // Another quarter of the duration elapses
    _jumpAheadByPercentOfRewardDuration(20);
    // The contract receives another reward, resetting the duration
    _mintTransferAndNotifyReward(_rewardAmount2);
    // Another quarter of the duration elapses
    _jumpAheadByPercentOfRewardDuration(20);
    // The contract receives another reward, resetting the duration
    _mintTransferAndNotifyReward(_rewardAmount3);
    // Another 20 percent of the duration elapses
    _jumpAheadByPercentOfRewardDuration(20);

    // The total staked by both depositors together
    uint256 _combinedStake = _stakeAmount1 + _stakeAmount2;
    // These are the total rewards distributed by the contract after the second depositor adds
    // their stake. It is the first reward for a fifth of the duration, plus the remaining 35% of
    // the first reward, plus 20% the second reward, for a fifth of the duration, plus the 80% of
    // the previous amount plus the third reward for 20% of the duration.
    uint256 _combinedPhaseExpectedTotalRewards = _percentOf(_rewardAmount1, 20)
      + _percentOf(_percentOf(_rewardAmount1, 35) + _rewardAmount2, 20)
      + _percentOf(
        _percentOf(_percentOf(_rewardAmount1, 35) + _rewardAmount2, 80) + _rewardAmount3, 20
      );

    // The second depositor should earn a share of the combined phase reward scaled by their
    // portion of the total stake.
    uint256 _depositor2ExpectedEarnings =
      (_stakeAmount2 * _combinedPhaseExpectedTotalRewards) / _combinedStake;

    // The first depositor earned all of the rewards for 20% of the duration, where the rewards
    // were from the first reward notification. The first depositor also earns a share of the
    // combined phase rewards proportional to his share of the stake.
    uint256 _depositor1ExpectedEarnings = _percentOf(_rewardAmount1, 20)
      + (_stakeAmount1 * _combinedPhaseExpectedTotalRewards) / _combinedStake;

    assertLteWithinOnePercent(govStaker.unclaimedReward(_depositId1), _depositor1ExpectedEarnings);
    assertLteWithinOnePercent(govStaker.unclaimedReward(_depositId2), _depositor2ExpectedEarnings);
  }

  function testFuzz_CalculatesEarningsThatAreLessThanOrEqualToRewardsReceived(
    address _depositor1,
    address _depositor2,
    address _delegatee,
    uint256 _stakeAmount1,
    uint256 _stakeAmount2,
    uint256 _rewardAmount,
    uint256 _durationPercent
  ) public {
    vm.assume(_depositor1 != _depositor2);

    (_stakeAmount1, _rewardAmount) = _boundToRealisticStakeAndReward(_stakeAmount1, _rewardAmount);
    _stakeAmount2 = _boundToRealisticStake(_stakeAmount2);
    _durationPercent = bound(_durationPercent, 0, 100);

    // A user deposits staking tokens
    (, GovernanceStaker.DepositIdentifier _depositId1) =
      _boundMintAndStake(_depositor1, _stakeAmount1, _delegatee);
    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);
    // A portion of the duration passes
    _jumpAheadByPercentOfRewardDuration(_durationPercent);
    // Another user deposits stake
    (, GovernanceStaker.DepositIdentifier _depositId2) =
      _boundMintAndStake(_depositor2, _stakeAmount2, _delegatee);
    // The rest of the duration elapses
    _jumpAheadByPercentOfRewardDuration(100 - _durationPercent);

    uint256 _earned1 = govStaker.unclaimedReward(_depositId1);
    uint256 _earned2 = govStaker.unclaimedReward(_depositId2);

    // Rewards earned by depositors should always at most equal to the actual reward amount
    assertLteWithinOnePercent(_earned1 + _earned2, _rewardAmount);
  }

  function test_CalculatesEarningsInAWayThatMitigatesRewardGriefing() public {
    address _depositor1 = makeAddr("Depositor 1");
    address _depositor2 = makeAddr("Depositor 2");
    address _depositor3 = makeAddr("Depositor 3");
    address _delegatee = makeAddr("Delegatee");
    address _attacker = makeAddr("Attacker");

    uint256 _smallDepositAmount = 0.1e18;
    uint256 _largeDepositAmount = 25_000_000e18;
    _mintGovToken(_depositor1, _smallDepositAmount);
    _mintGovToken(_depositor2, _smallDepositAmount);
    _mintGovToken(_depositor3, _largeDepositAmount);
    uint256 _rewardAmount = 1e14;
    rewardToken.mint(rewardNotifier, _rewardAmount);

    // The contract is notified of a reward
    vm.startPrank(rewardNotifier);
    rewardToken.transfer(address(govStaker), _rewardAmount);
    govStaker.notifyRewardAmount(_rewardAmount);
    vm.stopPrank();

    // User deposit staking tokens
    GovernanceStaker.DepositIdentifier _depositId1 =
      _stake(_depositor1, _smallDepositAmount, _delegatee);
    GovernanceStaker.DepositIdentifier _depositId2 =
      _stake(_depositor2, _smallDepositAmount, _delegatee);
    _stake(_depositor3, _largeDepositAmount, _delegatee);

    // Every block _attacker deposits 0 stake and assigns _depositor1 as claimer, thus leading
    // to frequent updates of the reward checkpoint for _depositor1, during which rounding errors
    // could accrue.
    GovernanceStaker.DepositIdentifier _depositId = _stake(_attacker, 0, _delegatee, _depositor1);
    for (uint256 i = 0; i < 1000; ++i) {
      _jumpAhead(12);
      vm.prank(_attacker);
      govStaker.stakeMore(_depositId, 0);
    }

    // Despite the attempted griefing attack, the unclaimed rewards for the two depositors should
    // be ~the same.
    assertLteWithinOnePercent(
      govStaker.unclaimedReward(_depositId1), govStaker.unclaimedReward(_depositId2)
    );
  }
}

contract ClaimReward is GovernanceStakerRewardsTest {
  function testFuzz_DepositorReceivesRewardsWhenClaiming(
    address _depositor,
    address _delegatee,
    address _claimer,
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    uint256 _durationPercent
  ) public {
    vm.assume(_depositor != address(govStaker));

    (_stakeAmount, _rewardAmount) = _boundToRealisticStakeAndReward(_stakeAmount, _rewardAmount);
    _durationPercent = bound(_durationPercent, 0, 100);

    // A user deposits staking tokens
    (, GovernanceStaker.DepositIdentifier _depositId) =
      _boundMintAndStake(_depositor, _stakeAmount, _delegatee, _claimer);
    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);
    // A portion of the duration passes
    _jumpAheadByPercentOfRewardDuration(_durationPercent);

    uint256 _earned = govStaker.unclaimedReward(_depositId);

    vm.prank(_depositor);
    govStaker.claimReward(_depositId);

    assertEq(rewardToken.balanceOf(_depositor), _earned);
  }

  function testFuzz_ClaimerReceivesRewardsWhenClaiming(
    address _depositor,
    address _delegatee,
    address _claimer,
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    uint256 _durationPercent
  ) public {
    vm.assume(_claimer != address(govStaker));

    (_stakeAmount, _rewardAmount) = _boundToRealisticStakeAndReward(_stakeAmount, _rewardAmount);
    _durationPercent = bound(_durationPercent, 0, 100);

    // A user deposits staking tokens
    (, GovernanceStaker.DepositIdentifier _depositId) =
      _boundMintAndStake(_depositor, _stakeAmount, _delegatee, _claimer);
    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);
    // A portion of the duration passes
    _jumpAheadByPercentOfRewardDuration(_durationPercent);

    uint256 _earned = govStaker.unclaimedReward(_depositId);

    vm.prank(_claimer);
    govStaker.claimReward(_depositId);

    assertEq(rewardToken.balanceOf(_claimer), _earned);
  }

  function testFuzz_ReturnsClaimedRewardAmount(
    address _depositor,
    address _delegatee,
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    uint256 _durationPercent
  ) public {
    vm.assume(_depositor != address(govStaker));

    (_stakeAmount, _rewardAmount) = _boundToRealisticStakeAndReward(_stakeAmount, _rewardAmount);
    _durationPercent = bound(_durationPercent, 0, 100);

    // A user deposits staking tokens
    (, GovernanceStaker.DepositIdentifier _depositId) =
      _boundMintAndStake(_depositor, _stakeAmount, _delegatee);
    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);
    // A portion of the duration passes
    _jumpAheadByPercentOfRewardDuration(_durationPercent);

    uint256 _earned = govStaker.unclaimedReward(_depositId);

    vm.prank(_depositor);
    uint256 _claimedAmount = govStaker.claimReward(_depositId);

    assertEq(_earned, _claimedAmount);
  }

  function testFuzz_ResetsTheRewardsEarnedByTheDeposit(
    address _depositor,
    address _delegatee,
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    uint256 _durationPercent
  ) public {
    (_stakeAmount, _rewardAmount) = _boundToRealisticStakeAndReward(_stakeAmount, _rewardAmount);
    _durationPercent = bound(_durationPercent, 0, 100);

    // A user deposits staking tokens
    (, GovernanceStaker.DepositIdentifier _depositId) =
      _boundMintAndStake(_depositor, _stakeAmount, _delegatee);
    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);
    // A portion of the duration passes
    _jumpAheadByPercentOfRewardDuration(_durationPercent);

    vm.prank(_depositor);
    govStaker.claimReward(_depositId);

    assertEq(govStaker.unclaimedReward(_depositId), 0);
  }

  function testFuzz_UpdatesDepositsEarningPower(
    address _depositor,
    address _delegatee,
    address _claimer,
    uint256 _rewardAmount,
    uint256 _stakeAmount,
    uint96 _newEarningPower
  ) public {
    vm.assume(_depositor != address(govStaker));
    (_stakeAmount, _rewardAmount) = _boundToRealisticStakeAndReward(_stakeAmount, _rewardAmount);

    // A user deposits staking tokens
    (, GovernanceStaker.DepositIdentifier _depositId) =
      _boundMintAndStake(_depositor, _stakeAmount, _delegatee, _claimer);
    vm.assume(_stakeAmount != _newEarningPower);

    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);
    _jumpAheadByPercentOfRewardDuration(100);

    earningPowerCalculator.__setEarningPowerAndIsQualifiedForDelegatee(
      _delegatee, _newEarningPower, true
    );

    vm.prank(_depositor);
    govStaker.claimReward(_depositId);

    GovernanceStaker.Deposit memory _deposit = _fetchDeposit(_depositId);

    assertEq(_deposit.earningPower, _newEarningPower);
  }

  function testFuzz_UpdatesGlobalTotalEarningPower(
    address _depositor,
    address _delegatee,
    address _claimer,
    uint256 _rewardAmount,
    uint96 _stakeAmount,
    uint96 _newEarningPower
  ) public {
    vm.assume(_depositor != address(govStaker));
    (_stakeAmount, _rewardAmount) = _boundToRealisticStakeAndReward(_stakeAmount, _rewardAmount);

    // A user deposits staking tokens
    (, GovernanceStaker.DepositIdentifier _depositId) =
      _boundMintAndStake(_depositor, _stakeAmount, _delegatee, _claimer);
    vm.assume(_stakeAmount != _newEarningPower);

    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);
    _jumpAheadByPercentOfRewardDuration(100);

    earningPowerCalculator.__setEarningPowerAndIsQualifiedForDelegatee(
      _delegatee, _newEarningPower, true
    );

    vm.prank(_depositor);
    govStaker.claimReward(_depositId);

    assertEq(govStaker.totalEarningPower(), _newEarningPower);
  }

  function testFuzz_UpdatesDepositorsTotalEarningPower(
    address _depositor,
    address _delegatee,
    address _claimer,
    uint256 _rewardAmount,
    uint256 _stakeAmount,
    uint96 _newEarningPower
  ) public {
    vm.assume(_depositor != address(govStaker));
    (_stakeAmount, _rewardAmount) = _boundToRealisticStakeAndReward(_stakeAmount, _rewardAmount);

    // A user deposits staking tokens
    (, GovernanceStaker.DepositIdentifier _depositId) =
      _boundMintAndStake(_depositor, _stakeAmount, _delegatee, _claimer);
    vm.assume(_stakeAmount != _newEarningPower);

    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);
    _jumpAheadByPercentOfRewardDuration(100);

    earningPowerCalculator.__setEarningPowerAndIsQualifiedForDelegatee(
      _delegatee, _newEarningPower, true
    );

    vm.prank(_depositor);
    govStaker.claimReward(_depositId);

    assertEq(govStaker.depositorTotalEarningPower(_depositor), _newEarningPower);
  }

  function testFuzz_EmitsAnEventWhenRewardsAreClaimedByDepositor(
    address _depositor,
    address _claimer,
    address _delegatee,
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    uint256 _durationPercent
  ) public {
    (_stakeAmount, _rewardAmount) = _boundToRealisticStakeAndReward(_stakeAmount, _rewardAmount);
    _durationPercent = bound(_durationPercent, 1, 100);

    // A user deposits staking tokens
    (, GovernanceStaker.DepositIdentifier _depositId) =
      _boundMintAndStake(_depositor, _stakeAmount, _delegatee, _claimer);
    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);
    // A portion of the duration passes
    _jumpAheadByPercentOfRewardDuration(_durationPercent);

    uint256 _earned = govStaker.unclaimedReward(_depositId);

    vm.expectEmit();
    emit GovernanceStaker.RewardClaimed(_depositId, _depositor, _earned);

    vm.prank(_depositor);
    govStaker.claimReward(_depositId);
  }

  function testFuzz_EmitsAnEventWhenRewardsAreClaimedByClaimer(
    address _depositor,
    address _claimer,
    address _delegatee,
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    uint256 _durationPercent
  ) public {
    (_stakeAmount, _rewardAmount) = _boundToRealisticStakeAndReward(_stakeAmount, _rewardAmount);
    _durationPercent = bound(_durationPercent, 1, 100);

    // A user deposits staking tokens
    (, GovernanceStaker.DepositIdentifier _depositId) =
      _boundMintAndStake(_depositor, _stakeAmount, _delegatee, _claimer);
    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);
    // A portion of the duration passes
    _jumpAheadByPercentOfRewardDuration(_durationPercent);

    uint256 _earned = govStaker.unclaimedReward(_depositId);

    vm.expectEmit();
    emit GovernanceStaker.RewardClaimed(_depositId, _claimer, _earned);

    vm.prank(_claimer);
    govStaker.claimReward(_depositId);
  }

  function testFuzz_SendsTheClaimFeeToTheFeeCollector(
    address _depositor,
    address _delegatee,
    address _claimer,
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    uint96 _feeAmount,
    address _feeCollector
  ) public {
    vm.assume(
      _depositor != address(govStaker) && _feeCollector != address(govStaker)
        && _feeCollector != address(0) && _depositor != _feeCollector
    );
    _feeAmount = uint96(bound(_feeAmount, 0, govStaker.MAX_CLAIM_FEE()));
    _stakeAmount = _boundToRealisticStake(_stakeAmount);
    _rewardAmount = bound(_rewardAmount, 1e18, 10_000_000e18);

    // The admin sets a claim fee
    _setClaimFeeAndCollector(_feeAmount, _feeCollector);
    // A user deposits staking tokens
    (, GovernanceStaker.DepositIdentifier _depositId) =
      _boundMintAndStake(_depositor, _stakeAmount, _delegatee, _claimer);
    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);
    // The full duration passes
    _jumpAheadByPercentOfRewardDuration(100);

    uint256 _earned = govStaker.unclaimedReward(_depositId);

    vm.prank(_depositor);
    govStaker.claimReward(_depositId);

    assertEq(rewardToken.balanceOf(_depositor), _earned - _feeAmount);
    assertEq(rewardToken.balanceOf(_feeCollector), _feeAmount);
  }

  function testFuzz_SubtractsTheFeeCollectedFromTheAmountReturned(
    address _depositor,
    address _delegatee,
    address _claimer,
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    uint96 _feeAmount,
    address _feeCollector
  ) public {
    vm.assume(
      _depositor != address(govStaker) && _feeCollector != address(govStaker)
        && _feeCollector != address(0) && _depositor != _feeCollector
    );
    _feeAmount = uint96(bound(_feeAmount, 0, govStaker.MAX_CLAIM_FEE()));
    _stakeAmount = _boundToRealisticStake(_stakeAmount);
    _rewardAmount = bound(_rewardAmount, 1e18, 10_000_000e18);

    // The admin sets a claim fee
    _setClaimFeeAndCollector(_feeAmount, _feeCollector);
    // A user deposits staking tokens
    (, GovernanceStaker.DepositIdentifier _depositId) =
      _boundMintAndStake(_depositor, _stakeAmount, _delegatee, _claimer);
    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);
    // The full duration passes
    _jumpAheadByPercentOfRewardDuration(100);

    uint256 _earned = govStaker.unclaimedReward(_depositId);

    vm.prank(_depositor);
    uint256 _rewardReturned = govStaker.claimReward(_depositId);

    assertEq(_rewardReturned, _earned - _feeAmount);
  }

  function testFuzz_SubtractsTheFeeCollectedFromTheAmountEmitted(
    address _depositor,
    address _delegatee,
    address _claimer,
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    uint96 _feeAmount,
    address _feeCollector
  ) public {
    vm.assume(
      _depositor != address(govStaker) && _feeCollector != address(govStaker)
        && _feeCollector != address(0) && _depositor != _feeCollector
    );
    _feeAmount = uint96(bound(_feeAmount, 0, govStaker.MAX_CLAIM_FEE()));
    _stakeAmount = _boundToRealisticStake(_stakeAmount);
    _rewardAmount = bound(_rewardAmount, 1e18, 10_000_000e18);

    // The admin sets a claim fee
    _setClaimFeeAndCollector(_feeAmount, _feeCollector);
    // A user deposits staking tokens
    (, GovernanceStaker.DepositIdentifier _depositId) =
      _boundMintAndStake(_depositor, _stakeAmount, _delegatee, _claimer);
    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);
    // The full duration passes
    _jumpAheadByPercentOfRewardDuration(100);

    uint256 _earned = govStaker.unclaimedReward(_depositId);

    vm.prank(_depositor);
    vm.expectEmit();
    emit GovernanceStaker.RewardClaimed(_depositId, _depositor, _earned - _feeAmount);
    govStaker.claimReward(_depositId);
  }

  function testFuzz_RevertIf_TheCallerIsNotTheDepositClaimerOrOwner(
    address _depositor,
    address _delegatee,
    address _claimer,
    address _notClaimer,
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    uint256 _durationPercent
  ) public {
    vm.assume(_notClaimer != _claimer && _notClaimer != _depositor);
    (_stakeAmount, _rewardAmount) = _boundToRealisticStakeAndReward(_stakeAmount, _rewardAmount);
    _durationPercent = bound(_durationPercent, 1, 100);

    // A user deposits staking tokens
    (, GovernanceStaker.DepositIdentifier _depositId) =
      _boundMintAndStake(_depositor, _stakeAmount, _delegatee, _claimer);
    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);
    // A portion of the duration passes
    _jumpAheadByPercentOfRewardDuration(_durationPercent);

    vm.prank(_notClaimer);
    vm.expectRevert(
      abi.encodeWithSelector(
        GovernanceStaker.GovernanceStaker__Unauthorized.selector,
        bytes32("not claimer or owner"),
        _notClaimer
      )
    );
    govStaker.claimReward(_depositId);
  }

  function testFuzz_RevertIf_UnclaimedRewardsAreLessThanTheFee(
    address _depositor,
    address _delegatee,
    address _claimer,
    uint256 _stakeAmount,
    address _feeCollector
  ) public {
    vm.assume(
      _depositor != address(govStaker) && _feeCollector != address(govStaker)
        && _feeCollector != address(0) && _depositor != _feeCollector
    );
    _stakeAmount = _boundToRealisticStake(_stakeAmount);
    uint256 _rewardAmount = govStaker.MAX_CLAIM_FEE();

    // The admin sets a claim fee
    _setClaimFeeAndCollector(uint96(govStaker.MAX_CLAIM_FEE()), _feeCollector);
    // A user deposits staking tokens
    (, GovernanceStaker.DepositIdentifier _depositId) =
      _boundMintAndStake(_depositor, _stakeAmount, _delegatee, _claimer);
    // The contract is notified of a reward
    _mintTransferAndNotifyReward(_rewardAmount);
    // The full duration passes
    _jumpAheadByPercentOfRewardDuration(100);

    vm.prank(_depositor);
    vm.expectRevert(stdError.arithmeticError);
    govStaker.claimReward(_depositId);
  }

  function testFuzz_SetsScaledEarningPowerWhenCalculatorScalesStakeAmount(
    address _depositor,
    address _delegatee,
    address _claimer,
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    uint256 _multiplierBips
  ) public {
    vm.assume(_depositor != address(govStaker));
    (_stakeAmount, _rewardAmount) = _boundToRealisticStakeAndReward(_stakeAmount, _rewardAmount);

    _multiplierBips = bound(_multiplierBips, 0, 20_000);
    earningPowerCalculator.__setMultiplierBips(_multiplierBips);

    (, GovernanceStaker.DepositIdentifier _depositId) =
      _boundMintAndStake(_depositor, _stakeAmount, _delegatee, _claimer);

    _mintTransferAndNotifyReward(_rewardAmount);
    _jumpAheadByPercentOfRewardDuration(100);

    vm.prank(_depositor);
    govStaker.claimReward(_depositId);

    uint256 _expectedEarningPower = (_stakeAmount * _multiplierBips) / 10_000;

    GovernanceStaker.Deposit memory _deposit = _fetchDeposit(_depositId);
    assertEq(_deposit.earningPower, _expectedEarningPower);
    assertEq(govStaker.totalEarningPower(), _expectedEarningPower);
    assertEq(govStaker.depositorTotalEarningPower(_depositor), _expectedEarningPower);
  }

  function testFuzz_SetsFixedEarningPowerWhenCalculatorReturnsConstantAmount(
    address _depositor,
    address _delegatee,
    address _claimer,
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    uint256 _fixedEarningPower
  ) public {
    vm.assume(_depositor != address(govStaker));
    (_stakeAmount, _rewardAmount) = _boundToRealisticStakeAndReward(_stakeAmount, _rewardAmount);
    _fixedEarningPower = _boundToRealisticStake(_fixedEarningPower);

    earningPowerCalculator.__setFixedReturn(_fixedEarningPower);

    (, GovernanceStaker.DepositIdentifier _depositId) =
      _boundMintAndStake(_depositor, _stakeAmount, _delegatee, _claimer);

    _mintTransferAndNotifyReward(_rewardAmount);
    _jumpAheadByPercentOfRewardDuration(100);

    vm.prank(_depositor);
    govStaker.claimReward(_depositId);

    GovernanceStaker.Deposit memory _deposit = _fetchDeposit(_depositId);
    assertEq(_deposit.earningPower, _fixedEarningPower);
    assertEq(govStaker.totalEarningPower(), _fixedEarningPower);
    assertEq(govStaker.depositorTotalEarningPower(_depositor), _fixedEarningPower);
  }
}

contract _FetchOrDeploySurrogate is GovernanceStakerRewardsTest {
  function testFuzz_EmitsAnEventWhenASurrogateIsDeployed(address _delegatee) public {
    vm.assume(_delegatee != address(0));
    vm.recordLogs();
    govStaker.exposed_fetchOrDeploySurrogate(_delegatee);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    DelegationSurrogate _surrogate = govStaker.surrogates(_delegatee);

    assertEq(logs[1].topics[0], keccak256("SurrogateDeployed(address,address)"));
    assertEq(logs[1].topics[1], bytes32(uint256(uint160(_delegatee))));
    assertEq(logs[1].topics[2], bytes32(uint256(uint160(address(_surrogate)))));
  }
}

contract Multicall is GovernanceStakerRewardsTest {
  function _encodeStake(address _delegatee, uint256 _stakeAmount)
    internal
    pure
    returns (bytes memory)
  {
    return
      abi.encodeWithSelector(bytes4(keccak256("stake(uint256,address)")), _stakeAmount, _delegatee);
  }

  function _encodeStake(address _delegatee, uint256 _stakeAmount, address _claimer)
    internal
    pure
    returns (bytes memory)
  {
    return abi.encodeWithSelector(
      bytes4(keccak256("stake(uint256,address,address)")), _stakeAmount, _delegatee, _claimer
    );
  }

  function _encodeStakeMore(GovernanceStaker.DepositIdentifier _depositId, uint256 _stakeAmount)
    internal
    pure
    returns (bytes memory)
  {
    return abi.encodeWithSelector(
      bytes4(keccak256("stakeMore(uint256,uint256)")), _depositId, _stakeAmount
    );
  }

  function _encodeWithdraw(GovernanceStaker.DepositIdentifier _depositId, uint256 _amount)
    internal
    pure
    returns (bytes memory)
  {
    return
      abi.encodeWithSelector(bytes4(keccak256("withdraw(uint256,uint256)")), _depositId, _amount);
  }

  function _encodeAlterClaimer(GovernanceStaker.DepositIdentifier _depositId, address _claimer)
    internal
    pure
    returns (bytes memory)
  {
    return abi.encodeWithSelector(
      bytes4(keccak256("alterClaimer(uint256,address)")), _depositId, _claimer
    );
  }

  function _encodeAlterDelegatee(GovernanceStaker.DepositIdentifier _depositId, address _delegatee)
    internal
    pure
    returns (bytes memory)
  {
    return abi.encodeWithSelector(
      bytes4(keccak256("alterDelegatee(uint256,address)")), _depositId, _delegatee
    );
  }

  function testFuzz_CanUseMulticallToStakeMultipleTimes(
    address _depositor,
    address _delegatee1,
    address _delegatee2,
    uint256 _stakeAmount1,
    uint256 _stakeAmount2
  ) public {
    _stakeAmount1 = _boundToRealisticStake(_stakeAmount1);
    _stakeAmount2 = _boundToRealisticStake(_stakeAmount2);
    vm.assume(_delegatee1 != address(0) && _delegatee2 != address(0));
    _mintGovToken(_depositor, _stakeAmount1 + _stakeAmount2);

    vm.prank(_depositor);
    govToken.approve(address(govStaker), _stakeAmount1 + _stakeAmount2);

    bytes[] memory _calls = new bytes[](2);
    _calls[0] = _encodeStake(_delegatee1, _stakeAmount1);
    _calls[1] = _encodeStake(_delegatee2, _stakeAmount2);
    vm.prank(_depositor);
    govStaker.multicall(_calls);
    assertEq(govStaker.depositorTotalStaked(_depositor), _stakeAmount1 + _stakeAmount2);
  }

  function testFuzz_CanUseMulticallToStakeAndAlterClaimerAndDelegatee(
    address _depositor,
    address _delegatee0,
    address _delegatee1,
    address _claimer0,
    address _claimer1,
    uint256 _stakeAmount0,
    uint256 _stakeAmount1,
    uint256 _timeElapsed
  ) public {
    _stakeAmount0 = _boundToRealisticStake(_stakeAmount0);
    _stakeAmount1 = _boundToRealisticStake(_stakeAmount1);

    vm.assume(
      _depositor != address(0) && _delegatee0 != address(0) && _delegatee1 != address(0)
        && _claimer0 != address(0) && _claimer1 != address(0)
    );
    _mintGovToken(_depositor, _stakeAmount0 + _stakeAmount1);

    vm.startPrank(_depositor);
    govToken.approve(address(govStaker), _stakeAmount0 + _stakeAmount1);

    // first, do initial stake without multicall
    GovernanceStaker.DepositIdentifier _depositId =
      govStaker.stake(_stakeAmount0, _delegatee0, _claimer0);

    // some time goes by...
    vm.warp(_timeElapsed);

    // now I want to stake more, and also change my delegatee and claimer
    bytes[] memory _calls = new bytes[](3);
    _calls[0] = _encodeStakeMore(_depositId, _stakeAmount1);
    _calls[1] = _encodeAlterClaimer(_depositId, _claimer1);
    _calls[2] = _encodeAlterDelegatee(_depositId, _delegatee1);
    govStaker.multicall(_calls);
    vm.stopPrank();

    (uint96 _amountResult,,, address _delegateeResult, address _claimerResult,,) =
      govStaker.deposits(_depositId);
    assertEq(govStaker.depositorTotalStaked(_depositor), _stakeAmount0 + _stakeAmount1);
    assertEq(govStaker.depositorTotalEarningPower(_depositor), _stakeAmount0 + _stakeAmount1);
    assertEq(_amountResult, _stakeAmount0 + _stakeAmount1);
    assertEq(_delegateeResult, _delegatee1);
    assertEq(_claimerResult, _claimer1);
  }
}
