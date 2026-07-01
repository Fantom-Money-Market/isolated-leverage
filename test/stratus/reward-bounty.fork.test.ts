import { ethers } from "hardhat";
import { expect } from "chai";
import { impersonateAccount, setBalance } from "@nomicfoundation/hardhat-network-helpers";

/**
 * Deterministic unit test for the reward-bounty split added to StratusShadowVault._harvest
 * this session. Gauge-reward CLAIMING itself is already validated live (gauge.getReward was
 * exercised on the deployed contract). What's new and unproven is the bountyBps>0 branch that
 * funds rebalanceViaSwap's bounty out of freshly-harvested rewards instead of the surplus
 * token. A MockGauge pays a fixed, known amount of a mintable MockERC20 on every getReward
 * call, so the keeper/protocolFee/holder split can be asserted exactly — no dependence on
 * live emission timing or amounts.
 *
 *   npx hardhat test test/stratus/reward-bounty.fork.test.ts --config hardhat.config.stratus.ts
 */
const VOTER = "0x9F59398D0a397b2EEB8a6123a6c7295cB0b0062D";
const POOL = "0x324963c267C354c7660Ce8CA3F5f167E05649970"; // wS/USDC.e ts=50 (gauged)
const wS = "0x039e2fB66102314Ce7b64Ce5Ce3E5183bc94aD38"; // token0 (18d)
const USDCe = "0x29219dd400f2Bf60E5a23d13Be72B486D4038894"; // token1 (6d)
const TICK_SPACING = 50;
const PROTOCOL_FEE = 5n; // %
const N_RANGES = 3n;
const REWARD_PER_CALL = ethers.parseEther("10"); // MockGauge payout per getReward() call

const ERC20 = [
  "function transfer(address,uint256) returns (bool)",
  "function approve(address,uint256) returns (bool)",
  "function balanceOf(address) view returns (uint256)",
];

async function fundFromPool(token: string, to: string, amount: bigint) {
  await impersonateAccount(POOL);
  await setBalance(POOL, ethers.parseEther("100"));
  const s = await ethers.getSigner(POOL);
  await new ethers.Contract(token, ERC20, s).transfer(to, amount);
}

describe("reward-bounty split (StratusShadowVault._harvest, MockGauge, Sonic fork)", () => {
  it("bountyBps==0 matches the proven live claim path; bountyBps>0 splits keeper/fee/holders correctly", async () => {
    const [owner, user, keeper] = await ethers.getSigners();

    // ---------- deploy the mock reward token + gauge ----------
    const mockToken = await (await ethers.getContractFactory("MockERC20")).deploy("Mock Reward", "MOCK");
    await mockToken.waitForDeployment();
    const mockTokenAddr = await mockToken.getAddress();

    const mockGauge = await (await ethers.getContractFactory("MockGauge")).deploy(mockTokenAddr, REWARD_PER_CALL);
    await mockGauge.waitForDeployment();
    const mockGaugeAddr = await mockGauge.getAddress();

    // ---------- stand up a real Shadow vault on a real gauged pool ----------
    const tm = await (await ethers.getContractFactory("TickMath")).deploy();
    const la = await (await ethers.getContractFactory("LiquidityAmounts")).deploy();
    const ph = await (await ethers.getContractFactory("UniswapV3PriceHelper", { libraries: { TickMath: await tm.getAddress() } })).deploy();
    const F = await ethers.getContractFactory("StratusShadowVaultFactory", { libraries: { TickMath: await tm.getAddress(), LiquidityAmounts: await la.getAddress(), UniswapV3PriceHelper: await ph.getAddress() } });
    const factory = await F.connect(owner).deploy(VOTER, mockTokenAddr); // default reward token = MOCK
    await factory.waitForDeployment();
    const factoryAddr = await factory.getAddress();

    const seed0 = ethers.parseEther("1");
    const seed1 = ethers.parseUnits("0.03", 6);
    await fundFromPool(wS, owner.address, seed0);
    await fundFromPool(USDCe, owner.address, seed1);
    await new ethers.Contract(wS, ERC20, owner).approve(factoryAddr, seed0);
    await new ethers.Contract(USDCe, ERC20, owner).approve(factoryAddr, seed1);
    await factory.createVault(USDCe, wS, TICK_SPACING, 100, PROTOCOL_FEE, seed0, seed1);

    const vault = await ethers.getContractAt("StratusShadowVault", await factory.vaultForPool(POOL));
    const vaultAddr = await vault.getAddress();

    // the real gauge was auto-wired from the voter; the default reward token (MOCK) too.
    expect(await vault.gauge()).to.not.equal(ethers.ZeroAddress);
    expect(await vault.rewardTokens(0)).to.equal(mockTokenAddr);

    // swap in the mock gauge so harvested amounts are fixed and known.
    await factory.setVaultGauge(vaultAddr, mockGaugeAddr);
    expect(await vault.gauge()).to.equal(mockGaugeAddr);

    // ===================== bountyBps==0 regression (collectGaugeRewards) =====================
    {
      const factoryBefore = await mockToken.balanceOf(factoryAddr);
      const vaultBefore = await mockToken.balanceOf(vaultAddr);

      await vault.connect(user).collectGaugeRewards(); // permissionless; bountyBps forced to 0

      const harvested = REWARD_PER_CALL * N_RANGES; // 3 ranges, 1 mock token, fixed payout each
      const fee = (harvested * PROTOCOL_FEE) / 100n;
      const net = harvested - fee;

      expect((await mockToken.balanceOf(factoryAddr)) - factoryBefore).to.equal(fee);
      // no bounty leg taken: the vault's own balance grows by exactly `net` (held to back
      // the reward-per-share accumulator, not paid out anywhere else).
      expect((await mockToken.balanceOf(vaultAddr)) - vaultBefore).to.equal(net);
    }

    // ===================== bountyBps>0 split (rebalanceViaSwap → _payRebalanceBounty) =====
    // Create a one-sided idle surplus (token0-heavy deposit, no rebalance after) so
    // rebalanceViaSwap has something to do.
    const dep0 = ethers.parseEther("10");
    const dep1 = ethers.parseUnits("0.01", 6);
    await fundFromPool(wS, user.address, dep0);
    await fundFromPool(USDCe, user.address, dep1);
    await new ethers.Contract(wS, ERC20, user).approve(vaultAddr, dep0);
    await new ethers.Contract(USDCe, ERC20, user).approve(vaultAddr, dep1);
    await vault.connect(user).deposit(dep0, dep1, user.address, 0);

    // generous deviation cap / skew floor so the real pool's natural spot-vs-TWAP gap passes;
    // 2% reward bounty (rewardBountyBps) is what we're asserting on.
    const REWARD_BOUNTY_BPS = 200n;
    await factory.setVaultRebalanceParams(vaultAddr, 500, 10, REWARD_BOUNTY_BPS, 7000);

    const [, quoteIn] = await vault.previewRebalanceSwap();
    const budget = quoteIn * 2n;
    await fundFromPool(USDCe, keeper.address, budget);
    await new ethers.Contract(USDCe, ERC20, keeper).approve(vaultAddr, budget);

    const factoryBefore = await mockToken.balanceOf(factoryAddr);
    const vaultBefore = await mockToken.balanceOf(vaultAddr);
    const keeperBefore = await mockToken.balanceOf(keeper.address);

    const [amountIn] = await vault.connect(keeper).rebalanceViaSwap.staticCall(budget, 0n);
    expect(amountIn).to.be.greaterThan(0n);
    await vault.connect(keeper).rebalanceViaSwap(budget, 0n);

    const harvested = REWARD_PER_CALL * N_RANGES; // fresh 30 MOCK harvested again (mock gauge doesn't deplete)
    const bounty = (harvested * REWARD_BOUNTY_BPS) / 10000n;
    const fee = ((harvested - bounty) * PROTOCOL_FEE) / 100n;
    const net = harvested - bounty - fee;

    expect((await mockToken.balanceOf(keeper.address)) - keeperBefore).to.equal(bounty);
    expect((await mockToken.balanceOf(factoryAddr)) - factoryBefore).to.equal(fee);
    expect((await mockToken.balanceOf(vaultAddr)) - vaultBefore).to.equal(net);
  });
});
