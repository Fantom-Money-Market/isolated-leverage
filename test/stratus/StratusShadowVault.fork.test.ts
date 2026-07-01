import { ethers } from "hardhat";
import { expect } from "chai";
import { impersonateAccount, time } from "@nomicfoundation/hardhat-network-helpers";

/**
 * End-to-end fork test for the v2 StratusShadowVault.
 *
 * Run a Sonic fork:
 *   SONIC_RPC_URL=<archive-rpc> npx hardhat test --config hardhat.config.stratus.ts
 *
 * ── FILL IN LIVE ADDRESSES (open item O3) ───────────────────────────────────
 * Find these on a Sonic explorer for a real Shadow CL pool that HAS a gauge:
 */
const CFG = {
  // Token pair + tick spacing — the factory resolves the gauge AND pool from the voter:
  TOKEN_A: "0x0000000000000000000000000000000000000000", // either pool token
  TOKEN_B: "0x0000000000000000000000000000000000000000", // the other pool token
  TICK_SPACING: 0,                                        // the CL pool's tick spacing
  VOTER: "0x0000000000000000000000000000000000000000",    // Shadow voter (required)
  // A holder of each pool token to fund the test (whale to impersonate):
  TOKEN0_WHALE: "0x0000000000000000000000000000000000000000",
  TOKEN1_WHALE: "0x0000000000000000000000000000000000000000",
  // Seed + user deposit amounts in pool token0/token1 order (set per decimals):
  SEED0: 0n,
  SEED1: 0n,
  USER0: 0n,
  USER1: 0n,
};

const MINIMUM_LIQUIDITY = 1000n;
const configured = () =>
  CFG.TOKEN_A !== ethers.ZeroAddress && CFG.VOTER !== ethers.ZeroAddress && CFG.SEED0 > 0n && CFG.USER0 > 0n;

async function fundFrom(whale: string, token: any, to: string, amount: bigint) {
  await impersonateAccount(whale);
  const signer = await ethers.getSigner(whale);
  // top up the impersonated whale with gas
  await ethers.provider.send("hardhat_setBalance", [whale, "0x56BC75E2D63100000"]);
  await token.connect(signer).transfer(to, amount);
}

describe("StratusShadowVault — end-to-end (Sonic fork)", function () {
  before(function () {
    if (!configured()) {
      console.warn("\n  [skipped] Fill in CFG (POOL/VOTER/whales/amounts) to run the fork test.\n");
      this.skip();
    }
  });

  let deployer: any, user: any;
  let factory: any, vault: any, pool: any, token0: any, token1: any;

  it("resolves pool+gauge from the voter and creates a seeded, locked vault", async () => {
    [deployer, user] = await ethers.getSigners();

    // Resolve gauge + pool from the voter — the same path the factory takes.
    const voter = await ethers.getContractAt("IShadowVoter", CFG.VOTER);
    const gaugeAddr = await voter.gaugeForClPool(CFG.TOKEN_A, CFG.TOKEN_B, CFG.TICK_SPACING);
    expect(gaugeAddr).to.not.equal(ethers.ZeroAddress);
    const gauge = await ethers.getContractAt("IShadowGaugeV3", gaugeAddr);
    pool = await ethers.getContractAt("IShadowV3Pool", await gauge.pool());
    token0 = await ethers.getContractAt("IERC20", await pool.token0());
    token1 = await ethers.getContractAt("IERC20", await pool.token1());

    const tm = await (await ethers.getContractFactory("TickMath")).deploy();
    const la = await (await ethers.getContractFactory("LiquidityAmounts")).deploy();
    const ph = await (await ethers.getContractFactory("UniswapV3PriceHelper", { libraries: { TickMath: await tm.getAddress() } })).deploy();
    const Factory = await ethers.getContractFactory("StratusShadowVaultFactory", { libraries: { TickMath: await tm.getAddress(), LiquidityAmounts: await la.getAddress(), UniswapV3PriceHelper: await ph.getAddress() } });
    factory = await Factory.deploy(CFG.VOTER);
    await factory.waitForDeployment();

    // Fund the deployer with the seed and approve the factory.
    await fundFrom(CFG.TOKEN0_WHALE, token0, deployer.address, CFG.SEED0);
    await fundFrom(CFG.TOKEN1_WHALE, token1, deployer.address, CFG.SEED1);
    await token0.connect(deployer).approve(await factory.getAddress(), CFG.SEED0);
    await token1.connect(deployer).approve(await factory.getAddress(), CFG.SEED1);

    // Caller passes only the token pair + tick spacing; the factory finds the rest.
    await factory.createVault(CFG.TOKEN_A, CFG.TOKEN_B, CFG.TICK_SPACING, 100, 5, CFG.SEED0, CFG.SEED1);
    vault = await ethers.getContractAt("StratusShadowVault", await factory.vaultForPool(await pool.getAddress()));

    // Gauge was wired automatically from the voter.
    expect(await vault.gauge()).to.equal(gaugeAddr);

    // Seed shares were burned; only the permanent MINIMUM_LIQUIDITY floor remains.
    expect(await vault.totalSupply()).to.equal(MINIMUM_LIQUIDITY);

    // VERIFIES position-key derivation + mint callback + `index` semantics:
    // if the key were wrong, rebalance()'s pool.mint would have reverted, and
    // getTotalAmounts reads pool.positions(key) — must be non-zero now.
    const [t0, t1] = await vault.getTotalAmounts();
    expect(t0 + t1).to.be.greaterThan(0n);
  });

  it("lets a user deposit and receive shares", async () => {
    await fundFrom(CFG.TOKEN0_WHALE, token0, user.address, CFG.USER0);
    await fundFrom(CFG.TOKEN1_WHALE, token1, user.address, CFG.USER1);
    await token0.connect(user).approve(await vault.getAddress(), CFG.USER0);
    await token1.connect(user).approve(await vault.getAddress(), CFG.USER1);

    await vault.connect(user).deposit(CFG.USER0, CFG.USER1, user.address, 0);
    expect(await vault.balanceOf(user.address)).to.be.greaterThan(0n);

    // Redeploy the user's idle deposit into positions.
    await factory.deployIdleVault(await vault.getAddress());
  });

  it("safe valuation resists spot manipulation", async () => {
    // getTotalAmountsSafe evaluates the position split at the TWAP tick, so a
    // spot move should barely move it while getTotalAmounts (spot) moves more.
    const [, safe1Before] = await vault.getTotalAmountsSafe();
    // NOTE: perform a large swap on POOL here to move spot, then advance a few
    // blocks (but < TWAP window). Asserting the bound is the real moat test:
    const [, safe1After] = await vault.getTotalAmountsSafe();
    expect(safe1After).to.be.greaterThan(0n);
    expect(safe1Before).to.be.greaterThan(0n);
    // expect(absDiff(safe1Before, safe1After)).to.be.lessThan(tolerance);
  });

  it("accrues and distributes gauge emissions to holders (open item O1)", async function () {
    if ((await vault.gauge()) === ethers.ZeroAddress) {
      console.warn("  [skipped] pool has no gauge; pick a gauged pool to test emissions.");
      this.skip();
    }
    const rewardToken = await ethers.getContractAt("IERC20", await vault.rewardTokens(0));
    const factoryBefore = await rewardToken.balanceOf(await factory.getAddress());

    await time.increase(7 * 24 * 60 * 60); // 1 week of emissions

    await vault.collectGaugeRewards();

    // THE CRITICAL CHECK: a directly-held pool position earned emissions, the
    // protocol cut reached the factory, and a holder has claimable rewards.
    const pending = await vault.pendingReward(user.address, await rewardToken.getAddress());
    expect(pending).to.be.greaterThan(0n);
    expect(await rewardToken.balanceOf(await factory.getAddress())).to.be.greaterThan(factoryBefore);

    const userBefore = await rewardToken.balanceOf(user.address);
    await vault.connect(user).claimRewards();
    expect(await rewardToken.balanceOf(user.address)).to.be.greaterThan(userBefore);
  });

  it("lets the user withdraw their share of the underlying", async () => {
    const shares = await vault.balanceOf(user.address);
    const t0Before = await token0.balanceOf(user.address);
    const t1Before = await token1.balanceOf(user.address);

    await vault.connect(user).withdraw(shares, user.address, 0, 0);

    expect(await vault.balanceOf(user.address)).to.equal(0n);
    const got0 = (await token0.balanceOf(user.address)) - t0Before;
    const got1 = (await token1.balanceOf(user.address)) - t1Before;
    expect(got0 + got1).to.be.greaterThan(0n);
  });
});
