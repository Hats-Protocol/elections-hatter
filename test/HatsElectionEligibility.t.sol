// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { Test, console2 } from "forge-std/Test.sol";
import { HatsElectionEligibility } from "../src/HatsElectionEligibility.sol";
import { Deploy, DeployPrecompiled } from "../script/Deploy.s.sol";
import {
  HatsModuleFactory, IHats, deployModuleInstance, deployModuleFactory
} from "hats-module/utils/DeployFunctions.sol";
import { IHats } from "hats-protocol/Interfaces/IHats.sol";

contract ModuleTest is Deploy, Test {
  /// @dev Inherit from DeployPrecompiled instead of Deploy if working with pre-compiled contracts

  /// @dev variables inhereted from Deploy script
  // Module public implementation;
  // bytes32 public SALT;

  uint256 public fork;
  uint256 public BLOCK_NUMBER = 17_671_864; // deployment block for Hats.sol
  IHats public HATS = IHats(0x3bc1A0Ad72417f2d411118085256fC53CBdDd137); // v1.hatsprotocol.eth
  HatsModuleFactory public factory;
  HatsElectionEligibility public instance;
  bytes public otherImmutableArgs;
  bytes public initArgs;

  address public org = makeAddr("org");
  address public ballotBox = makeAddr("ballotBox");
  address public candidate1 = makeAddr("candidate1");
  address public candidate2 = makeAddr("candidate2");
  address public nonWearer = makeAddr("nonWearer");

  address public caller;
  address[] public winners;

  uint256 public tophat;
  uint256 public hatter;
  uint256 public ballotBoxHat;
  uint256 public electedRoleHat;

  uint256 public currentTermEnd;
  uint256 public nextTermEnd;

  string public MODULE_VERSION;

  event ElectionOpened(uint256 nextTermEnd);
  event ElectionCompleted(uint256 termEnd, address[] winners);
  event NewTermStarted(uint256 termEnd);
  event Recalled(address[] accounts);

  error NotBallotBox();
  error NotOwner();
  error TooManyWinners();
  error ElectionClosed(uint256 termEnd);
  error InvalidTermEnd();
  error NotElected();
  error TermNotEnded();
  error TermEnded();
  error NextTermNotReady();

  function setUp() public virtual {
    // create and activate a fork, at BLOCK_NUMBER
    fork = vm.createSelectFork(vm.rpcUrl("mainnet"), BLOCK_NUMBER);

    // deploy implementation via the script
    prepare(false, MODULE_VERSION);
    run();

    // deploy the hats module factory
    factory = deployModuleFactory(HATS, SALT, "test factory");
  }
}

contract WithInstanceTest is ModuleTest {
  function setUp() public virtual override {
    super.setUp();

    // set up the hats
    tophat = HATS.mintTopHat(address(this), "org", "org/image");
    ballotBoxHat = HATS.createHat(tophat, "ballot box", 1, address(1), address(1), true, "");
    hatter = HATS.createHat(tophat, "hatter", 1, address(1), address(1), true, "");
    electedRoleHat = HATS.createHat(hatter, "elected role", 10, address(1), address(1), true, "");
    HATS.mintHat(ballotBoxHat, ballotBox);

    // set up the other immutable args
    otherImmutableArgs = abi.encodePacked(ballotBoxHat, tophat);

    // set up the init args
    currentTermEnd = block.timestamp + 1 days;
    initArgs = abi.encode(currentTermEnd);

    // deploy an instance of the module
    instance = HatsElectionEligibility(
      deployModuleInstance(factory, address(implementation), electedRoleHat, otherImmutableArgs, initArgs)
    );

    // finish setting up the hats
    HATS.mintHat(hatter, address(instance));
    HATS.changeHatEligibility(electedRoleHat, address(instance));
    HATS.transferHat(tophat, address(this), org);
  }

  function assertCorrectWinners(uint256 _termEnd, address[] memory _winners, bool _elected) public {
    for (uint256 i; i < _winners.length; ++i) {
      assertEq(instance.electionResults(_termEnd, _winners[i]), _elected, "incorrect winner");
    }
  }
}

contract Deployment is WithInstanceTest {
  /// @dev ensure that both the implementation and instance are properly initialized
  function test_initialization() public {
    // implementation
    vm.expectRevert("Initializable: contract is already initialized");
    implementation.setUp("setUp attempt");
    // instance
    vm.expectRevert("Initializable: contract is already initialized");
    instance.setUp("setUp attempt");
  }

  function test_version() public {
    assertEq(instance.version(), MODULE_VERSION);
  }

  function test_implementation() public {
    assertEq(address(instance.IMPLEMENTATION()), address(implementation));
  }

  function test_hats() public {
    assertEq(address(instance.HATS()), address(HATS));
  }

  function test_hatId() public {
    assertEq(instance.hatId(), electedRoleHat);
  }

  function test_ballotBoxHat() public {
    assertEq(instance.BALLOT_BOX_HAT(), ballotBoxHat);
  }

  function test_ownerHat() public {
    assertEq(instance.OWNER_HAT(), tophat);
  }

  function test_currentTermEnd() public {
    assertEq(instance.currentTermEnd(), currentTermEnd);
    assertEq(instance.nextTermEnd(), 0);
  }

  function test_currentElectionStatus() public {
    assertEq(instance.electionStatus(instance.currentTermEnd()), true);
  }
}

contract Electing is WithInstanceTest {
  function assertions_elect(uint256 _termEnd, address[] memory _winners, bool _elected, bool _status) public {
    assertCorrectWinners(_termEnd, _winners, _elected);
    assertEq(instance.electionStatus(_termEnd), _status, "incorrect election status");
  }

  function test_submitOneWinner() public submitter(ballotBox) electionStatus(true) {
    winners = new address[](1);
    winners[0] = candidate1;

    vm.expectEmit();
    emit ElectionCompleted(currentTermEnd, winners);

    vm.prank(caller);
    instance.elect(currentTermEnd, winners);

    assertions_elect(currentTermEnd, winners, true, false);
  }

  function test_submitTwoWinners() public submitter(ballotBox) electionStatus(true) {
    winners = new address[](2);
    winners[0] = candidate1;
    winners[1] = candidate2;

    vm.expectEmit();
    emit ElectionCompleted(currentTermEnd, winners);

    vm.prank(caller);
    instance.elect(currentTermEnd, winners);

    assertions_elect(currentTermEnd, winners, true, false);
  }

  function test_revert_notBallotBox() public submitter(nonWearer) electionStatus(true) {
    winners = new address[](1);
    winners[0] = candidate1;

    vm.expectRevert(NotBallotBox.selector);

    vm.prank(caller);
    instance.elect(currentTermEnd, winners);

    assertions_elect(currentTermEnd, winners, false, true);
  }

  function test_revert_electionClosed() public submitter(ballotBox) electionStatus(false) {
    winners = new address[](1);
    winners[0] = candidate1;

    vm.expectRevert(abi.encodeWithSelector(ElectionClosed.selector, currentTermEnd));

    vm.prank(caller);
    instance.elect(currentTermEnd, winners);

    assertions_elect(currentTermEnd, winners, false, false);
  }

  function test_tooManyWinners() public submitter(ballotBox) electionStatus(true) {
    // change max supply to 1
    vm.prank(org);
    HATS.changeHatMaxSupply(electedRoleHat, 1);

    // set up 1 too many winners
    winners = new address[](2);
    winners[0] = candidate1;
    winners[1] = candidate2;

    vm.expectRevert(TooManyWinners.selector);

    vm.prank(caller);
    instance.elect(currentTermEnd, winners);

    assertions_elect(currentTermEnd, winners, false, true);
  }

  modifier submitter(address _caller) {
    caller = _caller;
    _;
  }

  modifier electionStatus(bool _status) {
    if (!_status) {
      address[] memory preWinners = new address[](1);
      preWinners[0] = address(0);
      vm.prank(caller);
      instance.elect(currentTermEnd, preWinners);
    }
    _;
  }
}

contract SettingNextTerm is WithInstanceTest {
  uint256 public preSet;

  function setUp() public override {
    super.setUp();
    nextTermEnd = block.timestamp + 2 days;
    preSet = block.timestamp + 1 days + 12 hours;
  }

  function assertions_setNextTerm(uint256 _termEnd, bool _status) public {
    assertEq(instance.nextTermEnd(), _termEnd, "incorrect next term end");
    assertEq(instance.electionStatus(_termEnd), _status, "incorrect election status");
  }

  function test_set() public setter(org) alreadySetWithStatus(0, false) {
    vm.expectEmit();
    emit ElectionOpened(nextTermEnd);

    vm.prank(caller);
    instance.setNextTerm(nextTermEnd);

    assertions_setNextTerm(nextTermEnd, true);
  }

  function test_change() public setter(org) alreadySetWithStatus(preSet, true) {
    vm.expectEmit();
    emit ElectionOpened(nextTermEnd);

    vm.prank(caller);
    instance.setNextTerm(nextTermEnd);

    assertions_setNextTerm(nextTermEnd, true);
  }

  function test_revert_notOwner() public setter(nonWearer) alreadySetWithStatus(0, false) {
    vm.expectRevert(NotOwner.selector);

    vm.prank(caller);
    instance.setNextTerm(nextTermEnd);

    assertions_setNextTerm(0, false);
  }

  function test_revert_invalidTermEnd() public setter(org) alreadySetWithStatus(0, false) {
    vm.expectRevert(InvalidTermEnd.selector);

    vm.prank(caller);
    instance.setNextTerm(currentTermEnd - 1);

    assertions_setNextTerm(0, false);
  }

  function test_revert_electionClosed() public setter(org) alreadySetWithStatus(preSet, false) {
    vm.expectRevert(abi.encodeWithSelector(ElectionClosed.selector, preSet));

    vm.prank(caller);
    instance.setNextTerm(nextTermEnd);

    assertions_setNextTerm(preSet, false);
  }

  modifier setter(address _caller) {
    caller = _caller;
    _;
  }

  modifier alreadySetWithStatus(uint256 _preSet, bool _status) {
    if (_preSet > 0) {
      address[] memory preWinners = new address[](1);
      preWinners[0] = address(0);
      vm.prank(org);
      instance.setNextTerm(_preSet);
      if (!_status) {
        vm.prank(ballotBox);
        instance.elect(_preSet, preWinners);
      }
    }
    _;
  }
}

contract StartingNextTerm is WithInstanceTest {
  function setUp() public override {
    super.setUp();

    // submit some winners for the current term
    winners = new address[](2);
    winners[0] = candidate1;
    winners[1] = candidate2;
    vm.prank(ballotBox);
    instance.elect(currentTermEnd, winners);

    // prep next term
    nextTermEnd = block.timestamp + 2 days;
  }

  function assertions_startNextTerm(uint256 _current, uint256 _next, bool _status) public {
    assertEq(instance.currentTermEnd(), _current, "incorrect current term end");
    assertEq(instance.nextTermEnd(), _next, "incorrect next term end");
    assertEq(instance.electionStatus(_current), _status, "incorrect election status");
  }

  function test_start() public termEnded(true) nextTermSet(true) nextElectionClosed(true) {
    vm.expectEmit();
    emit NewTermStarted(nextTermEnd);

    instance.startNextTerm();

    assertions_startNextTerm(nextTermEnd, 0, false);
  }

  function test_revert_termNotEnded() public termEnded(false) nextTermSet(true) {
    vm.expectRevert(TermNotEnded.selector);

    instance.startNextTerm();

    assertions_startNextTerm(currentTermEnd, nextTermEnd, false);
  }

  function test_revert_nextTermNotSet() public termEnded(true) nextTermSet(false) {
    vm.expectRevert(NextTermNotReady.selector);

    instance.startNextTerm();

    assertions_startNextTerm(currentTermEnd, 0, false);
  }

  function test_revert_electionClosed() public termEnded(true) nextTermSet(true) nextElectionClosed(false) {
    vm.expectRevert(NextTermNotReady.selector);

    instance.startNextTerm();

    assertions_startNextTerm(currentTermEnd, nextTermEnd, false);
  }

  modifier termEnded(bool _ended) {
    currentTermEnd = instance.currentTermEnd();
    uint256 time = _ended ? currentTermEnd : currentTermEnd - 1;
    vm.warp(time);
    _;
  }

  modifier nextTermSet(bool _set) {
    if (_set) {
      vm.prank(org);
      instance.setNextTerm(nextTermEnd);
    }
    _;
  }

  modifier nextElectionClosed(bool _closed) {
    if (_closed) {
      address[] memory preWinners = new address[](1);
      preWinners[0] = address(0);
      vm.prank(ballotBox);
      instance.elect(nextTermEnd, preWinners);
    }
    _;
  }
}

contract Claiming is WithInstanceTest {
  function setUp() public override {
    super.setUp();

    // submit some winners
    winners = new address[](2);
    winners[0] = candidate1;
    winners[1] = candidate2;
    vm.prank(ballotBox);
    instance.elect(currentTermEnd, winners);
  }

  function assertions_claim(address _claimer, bool _elected) public {
    assertEq(HATS.isWearerOfHat(_claimer, electedRoleHat), _elected, "incorrect claim");
  }

  function test_claim() public claimer(candidate1) termEnded(false) {
    vm.prank(caller);
    instance.claim();

    assertions_claim(caller, true);
  }

  function test_claim_secondWinner() public claimer(candidate2) termEnded(false) {
    vm.prank(caller);
    instance.claim();

    assertions_claim(caller, true);
  }

  function test_revert_notElected() public claimer(nonWearer) termEnded(false) {
    vm.expectRevert(NotElected.selector);

    vm.prank(caller);
    instance.claim();

    assertions_claim(caller, false);
  }

  function test_revert_termEnded() public claimer(candidate1) termEnded(true) {
    vm.expectRevert(TermEnded.selector);

    vm.prank(caller);
    instance.claim();

    assertions_claim(caller, false);
  }

  modifier claimer(address _claimer) {
    caller = _claimer;
    _;
  }

  modifier termEnded(bool _ended) {
    currentTermEnd = instance.currentTermEnd();
    uint256 time = _ended ? currentTermEnd : currentTermEnd - 1;
    vm.warp(time);
    assertEq(instance.currentTermEnd() <= block.timestamp, _ended, "ended");
    _;
  }
}

contract Recalling is WithInstanceTest {
  address[] public recallees;

  function setUp() public override {
    super.setUp();

    // submit some winners
    winners = new address[](2);
    winners[0] = candidate1;
    winners[1] = candidate2;
    vm.prank(ballotBox);
    instance.elect(currentTermEnd, winners);
  }

  function assertions_recall(address[] memory _accounts, bool _recalled) public {
    for (uint256 i; i < _accounts.length; ++i) {
      assertEq(HATS.isWearerOfHat(_accounts[i], electedRoleHat), !_recalled, "incorrect recall");
    }
  }

  function test_recallOne() public recaller(ballotBox) {
    recallees = new address[](1);
    recallees[0] = candidate1;

    // candidate claims
    vm.prank(candidate1);
    instance.claim();

    vm.expectEmit();
    emit Recalled(recallees);

    vm.prank(caller);
    instance.recall(recallees);

    assertions_recall(recallees, true);
  }

  function test_recallMany() public recaller(ballotBox) {
    recallees = new address[](2);
    recallees[0] = candidate1;
    recallees[1] = candidate2;

    // candidates claim
    vm.prank(candidate1);
    instance.claim();
    vm.prank(candidate2);
    instance.claim();

    vm.expectEmit();
    emit Recalled(recallees);

    vm.prank(caller);
    instance.recall(recallees);

    assertions_recall(recallees, true);
  }

  function test_revert_notBallotBox() public recaller(nonWearer) {
    recallees = new address[](1);
    recallees[0] = candidate1;

    // candidate claims
    vm.prank(candidate1);
    instance.claim();

    vm.expectRevert(NotBallotBox.selector);

    vm.prank(caller);
    instance.recall(recallees);

    assertions_recall(recallees, false);
  }

  modifier recaller(address _caller) {
    caller = _caller;
    _;
  }
}

contract GettingWearerStatus is WithInstanceTest {
  address public wearer;

  function setUp() public override {
    super.setUp();

    // submit some winners
    winners = new address[](2);
    winners[0] = candidate1;
    winners[1] = candidate2;
    vm.prank(ballotBox);
    instance.elect(currentTermEnd, winners);
  }

  function assertions_getWearerStatus(address _wearer, bool _eligible, bool _standing) public {
    (bool eligible, bool standing) = instance.getWearerStatus(_wearer, electedRoleHat);
    assertEq(eligible, _eligible, "incorrect eligibility");
    assertEq(standing, _standing, "incorrect standing");
  }

  function test_eligible_elected_duringTerm() public wearer_(candidate1) duringTerm(true) {
    assertions_getWearerStatus(candidate1, true, true);
  }

  function test_notEligible_elected_afterTerm() public wearer_(candidate1) duringTerm(false) {
    assertions_getWearerStatus(candidate1, false, true);
  }

  function test_notEligible_notElected_duringTerm() public wearer_(nonWearer) duringTerm(true) {
    assertions_getWearerStatus(nonWearer, false, true);
  }

  modifier wearer_(address _wearer) {
    wearer = _wearer;
    _;
  }

  modifier duringTerm(bool _during) {
    currentTermEnd = instance.currentTermEnd();
    uint256 time = _during ? currentTermEnd - 1 : currentTermEnd;
    vm.warp(time);
    _;
  }
}
