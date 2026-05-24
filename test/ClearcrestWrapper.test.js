// Run: npx hardhat test
const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

// ---- Constants matching contract ----
const PERFORMANCE_FEE_BPS = 1500n;
const MIN_BUYBACK_USDC    = 10n * 10n ** 6n;
const OPS_CUT_BPS         = 10n;
const SNAPSHOT_INTERVAL   = 30n * 24n * 3600n;
const HOURLY_INTERVAL     = 3600n;
const DAILY_INTERVAL      = 86400n;
const DAYS_IN_MONTH       = 30n;

const usdc = (n) => BigInt(n) * 10n ** 6n;   // 6 decimals
const ccr  = (n) => BigInt(n) * 10n ** 18n;  // 18 decimals

describe("ClearcrestAutomationWrapper", function () {
  let wrapper, proxy;
  let mockVault, mockUSDC, mockCCR, mockRouter, mockFeed;
  let owner, team, holdback, lpSeed, reserve, user1, user2;

  beforeEach(async function () {
    [owner, team, holdback, lpSeed, reserve, user1, user2] = await ethers.getSigners();

    // ---- Deploy mocks ----
    mockVault  = await (await ethers.getContractFactory("MockEnzymeVault")).deploy(ethers.parseEther("1000000"));
    mockUSDC   = await (await ethers.getContractFactory("MockUSDC")).deploy();
    mockCCR    = await (await ethers.getContractFactory("MockCCRToken")).deploy();

    // 1 USDC (6 dec) -> 1e12 units = 1 CCR (18 dec)
    mockRouter = await (await ethers.getContractFactory("MockCamelotRouter")).deploy(
      await mockCCR.getAddress(), 10n ** 12n
    );

    // CCR price = $1.00, 8-decimal feed
    mockFeed   = await (await ethers.getContractFactory("MockPriceFeed")).deploy(1n * 10n ** 8n, 8);

    await mockCCR.mint(await mockRouter.getAddress(), ccr(1_000_000));

    // ---- Deploy UUPS proxy ----
    const Factory = await ethers.getContractFactory("ClearcrestAutomationWrapper");
    proxy = await upgrades.deployProxy(
      Factory,
      [team.address, holdback.address, lpSeed.address, reserve.address],
      {
        kind: "uups",
        constructorArgs: [
          await mockVault.getAddress(),
          await mockCCR.getAddress(),
          await mockUSDC.getAddress(),
          await mockRouter.getAddress(),
          await mockFeed.getAddress(),
        ],
        initializer: "initialize",
        unsafeAllow: ["constructor"],
      }
    );

    wrapper = await ethers.getContractAt("ClearcrestAutomationWrapper", await proxy.getAddress());
  });

  // ================================================================
  // DEPLOYMENT
  // ================================================================
  describe("Deployment", function () {
    it("sets owner correctly", async function () {
      expect(await wrapper.owner()).to.equal(owner.address);
    });

    it("sets all wallets correctly", async function () {
      expect(await wrapper.teamWallet()).to.equal(team.address);
      expect(await wrapper.holdbackWallet()).to.equal(holdback.address);
      expect(await wrapper.lpSeedWallet()).to.equal(lpSeed.address);
      expect(await wrapper.reserveWallet()).to.equal(reserve.address);
    });

    it("sets highWaterMark from vault", async function () {
      expect(await wrapper.highWaterMark()).to.equal(ethers.parseEther("1000000"));
    });

    it("sets estimatedGasCostUSDC to 250000", async function () {
      expect(await wrapper.estimatedGasCostUSDC()).to.equal(250_000n);
    });

    it("reverts constructor with zero vault address", async function () {
      const Factory = await ethers.getContractFactory("ClearcrestAutomationWrapper");
      await expect(
        Factory.deploy(
          ethers.ZeroAddress,
          await mockCCR.getAddress(),
          await mockUSDC.getAddress(),
          await mockRouter.getAddress(),
          await mockFeed.getAddress()
        )
      ).to.be.revertedWith("zero vault");
    });
  });

  // ================================================================
  // FEE DISTRIBUTION
  // ================================================================
  describe("Fee Distribution", function () {
    beforeEach(async function () {
      await mockUSDC.mint(await wrapper.getAddress(), usdc(1000));
    });

    it("distributes fees in correct proportions", async function () {
      const yieldAmount = usdc(1000);
      const perfFee     = (yieldAmount * PERFORMANCE_FEE_BPS) / 10000n;

      const [teamBefore, holdbackBefore, lpBefore, reserveBefore] = await Promise.all([
        mockUSDC.balanceOf(team.address),
        mockUSDC.balanceOf(holdback.address),
        mockUSDC.balanceOf(lpSeed.address),
        mockUSDC.balanceOf(reserve.address),
      ]);

      await wrapper.connect(owner).recordStakingYield(yieldAmount);

      const [teamAfter, holdbackAfter, lpAfter, reserveAfter] = await Promise.all([
        mockUSDC.balanceOf(team.address),
        mockUSDC.balanceOf(holdback.address),
        mockUSDC.balanceOf(lpSeed.address),
        mockUSDC.balanceOf(reserve.address),
      ]);

      expect(teamAfter    - teamBefore).to.equal((perfFee * 45n) / 100n);
      // holdback receives its 20% share (may also receive ops cuts from burn-share swap)
      expect(holdbackAfter - holdbackBefore).to.be.gte((perfFee * 20n) / 100n);
      expect(lpAfter      - lpBefore).to.equal((perfFee * 10n) / 100n);
      expect(reserveAfter - reserveBefore).to.equal((perfFee * 5n) / 100n);
    });

    it("adds buybackShare (15%) to accumulator", async function () {
      const yieldAmount = usdc(1000);
      const perfFee     = (yieldAmount * PERFORMANCE_FEE_BPS) / 10000n;
      const expected    = (perfFee * 15n) / 100n;

      await wrapper.connect(owner).recordStakingYield(yieldAmount);
      expect(await wrapper.buybackAccumulator()).to.be.gte(expected);
    });

    it("routes burnShare dust to accumulator if below MIN_BUYBACK", async function () {
      await mockUSDC.mint(await wrapper.getAddress(), usdc(10));
      const tinyYield = usdc(10); // perfFee = $1.50, burnShare = $0.075 < $10 MIN
      const accBefore = await wrapper.buybackAccumulator();
      await wrapper.connect(owner).recordStakingYield(tinyYield);
      expect(await wrapper.buybackAccumulator()).to.be.gt(accBefore);
    });

    it("reverts if contract has insufficient USDC", async function () {
      await expect(
        wrapper.connect(owner).recordStakingYield(usdc(1_000_000))
      ).to.be.revertedWith("CCR: insufficient USDC");
    });

    it("emits FeesDistributed event", async function () {
      await mockUSDC.mint(await wrapper.getAddress(), usdc(1000));
      const perfFee = (usdc(1000) * PERFORMANCE_FEE_BPS) / 10000n;
      await expect(wrapper.connect(owner).recordStakingYield(usdc(1000)))
        .to.emit(wrapper, "FeesDistributed")
        .withArgs(perfFee);
    });

    it("emits PerformanceFeeCollected event", async function () {
      const yield_ = usdc(1000);
      const fee    = (yield_ * PERFORMANCE_FEE_BPS) / 10000n;
      await expect(wrapper.connect(owner).recordStakingYield(yield_))
        .to.emit(wrapper, "PerformanceFeeCollected")
        .withArgs(yield_, fee);
    });

    it("only owner can call recordStakingYield", async function () {
      await expect(
        wrapper.connect(user1).recordStakingYield(usdc(1000))
      ).to.be.revertedWithCustomError(wrapper, "OwnableUnauthorizedAccount");
    });

    it("reverts on zero yield", async function () {
      await expect(
        wrapper.connect(owner).recordStakingYield(0)
      ).to.be.revertedWith("zero yield");
    });
  });

  // ================================================================
  // MONTHLY SNAPSHOT
  // ================================================================
  describe("Monthly Snapshot", function () {
    beforeEach(async function () {
      await mockUSDC.mint(await wrapper.getAddress(), usdc(10_000));
      await wrapper.connect(owner).recordStakingYield(usdc(10_000));
    });

    it("sets daily and hourly amounts correctly after snapshot", async function () {
      const accBefore = await wrapper.buybackAccumulator();
      expect(accBefore).to.be.gt(0n);

      await time.increase(Number(SNAPSHOT_INTERVAL) + 1);

      const [upkeepNeeded, data] = await wrapper.checkUpkeep("0x");
      expect(upkeepNeeded).to.be.true;
      expect(ethers.AbiCoder.defaultAbiCoder().decode(["uint8"], data)[0]).to.equal(0);

      await wrapper.performUpkeep(
        ethers.AbiCoder.defaultAbiCoder().encode(["uint8"], [0])
      );

      expect(await wrapper.dailyBuybackAmount()).to.equal(accBefore / DAYS_IN_MONTH);
      expect(await wrapper.hourlyBuybackAmount()).to.equal((accBefore / DAYS_IN_MONTH) / 24n);
    });

    it("resets accumulator to zero after snapshot", async function () {
      await time.increase(Number(SNAPSHOT_INTERVAL) + 1);
      await wrapper.performUpkeep(
        ethers.AbiCoder.defaultAbiCoder().encode(["uint8"], [0])
      );
      expect(await wrapper.buybackAccumulator()).to.equal(0n);
    });

    it("emits MonthlySnapshotTaken event", async function () {
      await time.increase(Number(SNAPSHOT_INTERVAL) + 1);
      await expect(
        wrapper.performUpkeep(
          ethers.AbiCoder.defaultAbiCoder().encode(["uint8"], [0])
        )
      ).to.emit(wrapper, "MonthlySnapshotTaken");
    });
  });

  // ================================================================
  // BUYBACK ENGINE
  // ================================================================
  describe("Buyback Engine", function () {
    beforeEach(async function () {
      await mockUSDC.mint(await wrapper.getAddress(), usdc(100_000));
      await wrapper.connect(owner).recordStakingYield(usdc(100_000));

      await time.increase(Number(SNAPSHOT_INTERVAL) + 1);
      await wrapper.performUpkeep(
        ethers.AbiCoder.defaultAbiCoder().encode(["uint8"], [0])
      );
    });

    it("executes hourly buyback when amount >= gas cost", async function () {
      const hourly  = await wrapper.hourlyBuybackAmount();
      const gasCost = await wrapper.estimatedGasCostUSDC();

      if (hourly < gasCost) {
        await wrapper.connect(owner).setEstimatedGasCost(1n);
      }

      await time.increase(Number(HOURLY_INTERVAL) + 1);

      const [upkeepNeeded, data] = await wrapper.checkUpkeep("0x");
      expect(upkeepNeeded).to.be.true;

      const ccrBurnedBefore = await mockCCR.totalBurned();
      await wrapper.performUpkeep(data);
      expect(await mockCCR.totalBurned()).to.be.gt(ccrBurnedBefore);
    });

    it("sends 0.1% ops cut to holdback on buyback", async function () {
      await wrapper.connect(owner).setEstimatedGasCost(1n);
      await time.increase(Number(HOURLY_INTERVAL) + 1);

      const holdbackBefore = await mockUSDC.balanceOf(holdback.address);
      const hourlyAmt      = await wrapper.hourlyBuybackAmount();

      await wrapper.performUpkeep(
        ethers.AbiCoder.defaultAbiCoder().encode(["uint8"], [1])
      );

      const expectedOpsCut = (hourlyAmt * OPS_CUT_BPS) / 10000n;
      expect(await mockUSDC.balanceOf(holdback.address) - holdbackBefore).to.be.gte(expectedOpsCut);
    });

    it("emits BuybackExecuted event", async function () {
      await wrapper.connect(owner).setEstimatedGasCost(1n);
      await time.increase(Number(HOURLY_INTERVAL) + 1);
      await expect(
        wrapper.performUpkeep(
          ethers.AbiCoder.defaultAbiCoder().encode(["uint8"], [1])
        )
      ).to.emit(wrapper, "BuybackExecuted");
    });

    it("falls back to daily if hourly amount < gas cost", async function () {
      const hourly = await wrapper.hourlyBuybackAmount();

      await wrapper.connect(owner).setEstimatedGasCost(hourly + 1n);
      await time.increase(Number(DAILY_INTERVAL) + 1);

      const [upkeepNeeded, data] = await wrapper.checkUpkeep("0x");
      expect(upkeepNeeded).to.be.true;
      expect(ethers.AbiCoder.defaultAbiCoder().decode(["uint8"], data)[0]).to.equal(2);
    });
  });

  // ================================================================
  // CHECKUPKEEP PRIORITY
  // ================================================================
  describe("checkUpkeep Priority", function () {
    it("returns false initially (no snapshot due, no buyback amounts)", async function () {
      const [needed] = await wrapper.checkUpkeep("0x");
      expect(needed).to.be.false;
    });

    it("returns action 0 when monthly snapshot due", async function () {
      await time.increase(Number(SNAPSHOT_INTERVAL) + 1);
      const [needed, data] = await wrapper.checkUpkeep("0x");
      expect(needed).to.be.true;
      expect(ethers.AbiCoder.defaultAbiCoder().decode(["uint8"], data)[0]).to.equal(0);
    });

    it("monthly snapshot takes priority over hourly buyback", async function () {
      await mockUSDC.mint(await wrapper.getAddress(), usdc(100_000));
      await wrapper.connect(owner).recordStakingYield(usdc(100_000));
      await time.increase(Number(SNAPSHOT_INTERVAL) + 1);

      const [, data] = await wrapper.checkUpkeep("0x");
      expect(ethers.AbiCoder.defaultAbiCoder().decode(["uint8"], data)[0]).to.equal(0);
    });
  });

  // ================================================================
  // ADMIN FUNCTIONS
  // ================================================================
  describe("Admin Functions", function () {
    it("owner can update teamWallet", async function () {
      await wrapper.connect(owner).setTeamWallet(user1.address);
      expect(await wrapper.teamWallet()).to.equal(user1.address);
    });

    it("reverts setTeamWallet with zero address", async function () {
      await expect(
        wrapper.connect(owner).setTeamWallet(ethers.ZeroAddress)
      ).to.be.revertedWith("zero address");
    });

    it("non-owner cannot update wallets", async function () {
      await expect(
        wrapper.connect(user1).setTeamWallet(user1.address)
      ).to.be.revertedWithCustomError(wrapper, "OwnableUnauthorizedAccount");
    });

    it("owner can blacklist and unblacklist", async function () {
      await wrapper.connect(owner).blacklist(user1.address);
      expect(await wrapper.blacklisted(user1.address)).to.be.true;
      await wrapper.connect(owner).unblacklist(user1.address);
      expect(await wrapper.blacklisted(user1.address)).to.be.false;
    });

    it("owner can pause and unpause", async function () {
      await wrapper.connect(owner).pause();
      expect(await wrapper.paused()).to.be.true;
      await wrapper.connect(owner).unpause();
      expect(await wrapper.paused()).to.be.false;
    });

    it("performUpkeep reverts when paused", async function () {
      await wrapper.connect(owner).pause();
      await time.increase(Number(SNAPSHOT_INTERVAL) + 1);
      await expect(
        wrapper.performUpkeep(
          ethers.AbiCoder.defaultAbiCoder().encode(["uint8"], [0])
        )
      ).to.be.revertedWithCustomError(wrapper, "EnforcedPause");
    });

    it("owner can rescue non-core tokens", async function () {
      const extra = await (await ethers.getContractFactory("MockUSDC")).deploy();
      await extra.mint(await wrapper.getAddress(), usdc(100));
      await wrapper.connect(owner).rescueTokens(
        await extra.getAddress(), owner.address, usdc(100)
      );
      expect(await extra.balanceOf(owner.address)).to.equal(usdc(100));
    });

    it("cannot rescue USDC or CCR", async function () {
      await expect(
        wrapper.connect(owner).rescueTokens(
          await mockUSDC.getAddress(), owner.address, usdc(100)
        )
      ).to.be.revertedWith("cannot rescue core tokens");
    });

    it("owner can update gas cost estimate", async function () {
      await wrapper.connect(owner).setEstimatedGasCost(500_000n);
      expect(await wrapper.estimatedGasCostUSDC()).to.equal(500_000n);
    });
  });

  // ================================================================
  // UPGRADABILITY (UUPS)
  // ================================================================
  describe("Upgradability (UUPS)", function () {
    const constructorArgs = async () => [
      await mockVault.getAddress(),
      await mockCCR.getAddress(),
      await mockUSDC.getAddress(),
      await mockRouter.getAddress(),
      await mockFeed.getAddress(),
    ];

    it("only owner can upgrade", async function () {
      const Factory = await ethers.getContractFactory("ClearcrestAutomationWrapper");
      await expect(
        upgrades.upgradeProxy(await proxy.getAddress(), Factory.connect(user1), {
          kind: "uups",
          constructorArgs: await constructorArgs(),
          unsafeAllow: ["constructor"],
        })
      ).to.be.reverted;
    });

    it("preserves state after upgrade", async function () {
      const teamBefore = await wrapper.teamWallet();
      const Factory    = await ethers.getContractFactory("ClearcrestAutomationWrapper");
      await upgrades.upgradeProxy(await proxy.getAddress(), Factory, {
        kind: "uups",
        constructorArgs: await constructorArgs(),
        unsafeAllow: ["constructor"],
      });
      expect(await wrapper.teamWallet()).to.equal(teamBefore);
    });
  });

  // ================================================================
  // ORACLE FALLBACK
  // ================================================================
  describe("Oracle Fallback", function () {
    it("uses fallback slippage when oracle is stale", async function () {
      await mockFeed.setStale();
      await mockUSDC.mint(await wrapper.getAddress(), usdc(1000));
      await wrapper.connect(owner).setEstimatedGasCost(1n);

      await wrapper.connect(owner).recordStakingYield(usdc(1000));
      await time.increase(Number(SNAPSHOT_INTERVAL) + 1);
      await wrapper.performUpkeep(
        ethers.AbiCoder.defaultAbiCoder().encode(["uint8"], [0])
      );

      await time.increase(Number(HOURLY_INTERVAL) + 1);
      await expect(
        wrapper.performUpkeep(
          ethers.AbiCoder.defaultAbiCoder().encode(["uint8"], [1])
        )
      ).to.not.be.reverted;
    });
  });
});
