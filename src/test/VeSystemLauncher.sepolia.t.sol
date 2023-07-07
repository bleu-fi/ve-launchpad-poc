// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;
pragma abicoder v2;

import "forge-std/Test.sol";

import "./helpers/MyToken.sol";
import "../RewardDistributor.sol";
import "../IBleuVotingEscrow.sol";
import "../IVeSystemFactory.sol";

import {
    WeightedPoolFactory
} from "lib/balancer-v2-monorepo/pkg/pool-weighted/contracts/WeightedPoolFactory.sol";
import {
    ContractDeploymentHelper,
    TestTokensHelper,
    LocalBalancerDeploymentEnvironment,
    WeightedPoolCreatorHelper,
    BalancerDeploymentEnvironment
} from "./helpers/E2EHelpers.sol";
import {
    WeightedPool
} from "lib/balancer-v2-monorepo/pkg/pool-weighted/contracts/WeightedPool.sol";

import {
    WeightedPoolUserData
} from "lib/balancer-v2-monorepo/pkg/interfaces/contracts/pool-weighted/WeightedPoolUserData.sol";
import {
    IVault,
    Vault,
    IWETH
} from "lib/balancer-v2-monorepo/pkg/vault/contracts/Vault.sol";
import {
    WeightedPoolFactory
} from "lib/balancer-v2-monorepo/pkg/pool-weighted/contracts/WeightedPoolFactory.sol";

contract SepoliaBalancerDeploymentEnvironment is BalancerDeploymentEnvironment {
    constructor() {
        _vault = IVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
        _weightedPoolFactory = WeightedPoolFactory(
            0x7920BFa1b2041911b354747CA7A6cDD2dfC50Cfd
        );

    }
}

contract VeSystemLauncherSepoliaTest is
    Test,
    SepoliaBalancerDeploymentEnvironment,
    WeightedPoolCreatorHelper,
    ContractDeploymentHelper
{
    IVeSystemFactory internal _veSystemFactory;
    IBleuVotingEscrow internal _votingEscrowBlueprint;
    IBleuVotingEscrow internal _veBleu;
    IRewardDistributor internal _rewardDistributorBlueprint;
    IRewardDistributor internal _rewardDistributorBleu;

    constructor() {
        _votingEscrowBlueprint = IBleuVotingEscrow(
            _deploymentHelper.deployVyperBlueprint("VotingEscrowBlueprint")
        );
        _rewardDistributorBlueprint = IRewardDistributor(
            _deploymentHelper.deploySolidityBlueprint(
                "RewardDistributor.sol:RewardDistributor"
            )
        );
        _veSystemFactory = IVeSystemFactory(
            _deploymentHelper.deployVyperContract(
                "VeSystemFactory",
                abi.encode(
                    address(_votingEscrowBlueprint),
                    address(_rewardDistributorBlueprint)
                )
            )
        );

        (
            address _veBleuAddress,
            address _veBleuRewardAddress
        ) = _veSystemFactory.deploy(
                address(_weightedPool),
                "Bleu",
                "BLEU",
                WEEK
            );
        _veBleu = IBleuVotingEscrow(_veBleuAddress);
        _rewardDistributorBleu = IRewardDistributor(_veBleuRewardAddress);
    }

    function testBlueprints() public {
        assertEq(
            _veSystemFactory.votingEscrowBlueprint(),
            address(_votingEscrowBlueprint)
        );
        assertEq(
            _veSystemFactory.rewardDistributorBlueprint(),
            address(_rewardDistributorBlueprint)
        );
    }

    function testVotingEscrow() public {
        assert(_veSystemFactory.votingEscrowRegister(address(_veBleu)));
        assertEq(_veBleu.token(), address(_weightedPool));
        assertEq(_veBleu.admin(), address(this));

        assertEq(_veBleu.totalSupply(), 0);
        uint256 _BPTBeforeLock = _weightedPool.balanceOf(address(this));

        _weightedPool.approve(address(_veBleu), _BPTBeforeLock);
        _veBleu.create_lock(_BPTBeforeLock, block.timestamp + YEAR);

        assertEq(_weightedPool.balanceOf(address(this)), 0);
        assertGt(_veBleu.totalSupply(), 0);
        assertEq(_veBleu.totalSupply(block.timestamp + YEAR), 0);
        _veBleu.checkpoint();

        assertGt(_veBleu.balanceOf(address(this)), 0);
    }

    function testRewardDistribution() public {
        address alice = address(1);
        address bob = address(2);

        // Alice joins on the pool
        uint256[] memory aliceAmounts = new uint256[](2);
        aliceAmounts[0] = 100e18;
        aliceAmounts[1] = 400e18;
        joinPoolHelper(
            _vault,
            _weightedPool,
            _poolTokens,
            alice,
            aliceAmounts,
            abi.encode(
                WeightedPoolUserData.JoinKind.EXACT_TOKENS_IN_FOR_BPT_OUT,
                aliceAmounts,
                1e18
            )
        );

        // Alice locks BPT into the voting escrow
        uint256 aliceBPTAmount = _weightedPool.balanceOf(address(alice));
        vm.startPrank(alice);
        _weightedPool.approve(address(_veBleu), aliceBPTAmount);
        _veBleu.create_lock(aliceBPTAmount, block.timestamp + YEAR);
        vm.stopPrank();

        // Bob joins on the pool
        uint256[] memory bobAmounts = new uint256[](2);
        bobAmounts[0] = aliceAmounts[0] * 2;
        bobAmounts[1] = aliceAmounts[1] * 2;
        joinPoolHelper(
            _vault,
            _weightedPool,
            _poolTokens,
            bob,
            bobAmounts,
            abi.encode(
                WeightedPoolUserData.JoinKind.EXACT_TOKENS_IN_FOR_BPT_OUT,
                bobAmounts,
                1e18
            )
        );

        // Bob locks BPT into the voting escrow
        uint256 bobBPTAmount = _weightedPool.balanceOf(address(bob));
        vm.startPrank(bob);
        _weightedPool.approve(address(_veBleu), bobBPTAmount);
        _veBleu.create_lock(bobBPTAmount, block.timestamp + YEAR);
        vm.stopPrank();

        // One week later, admin deposits 90 RewardToken in RewardDistributor;
        vm.warp(WEEK + block.timestamp);
        _bleu.approve(address(_rewardDistributorBleu), 90e18);
        _rewardDistributorBleu.depositToken(_bleu, 90e18);
        _rewardDistributorBleu.checkpoint();

        vm.warp((WEEK * 2) + block.timestamp);

        // Two weeks later, bob and alice claims tokens;
        _rewardDistributorBleu.claimToken(alice, _bleu);
        _rewardDistributorBleu.claimToken(bob, _bleu);

        // Check that alice and bob have the correct amount of tokens
        assertApproxEqRel(_bleu.balanceOf(address(alice)), 30e18, 1e6);
        assertApproxEqRel(_bleu.balanceOf(address(bob)), 60e18, 1e6);
        assertApproxEqRel(
            _bleu.balanceOf(address(alice)) + _bleu.balanceOf(address(bob)),
            90e18,
            1e6
        );
    }
}
