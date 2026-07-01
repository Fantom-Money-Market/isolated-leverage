import { ethers } from "hardhat";
import { expect } from "chai";
import { impersonateAccount, setBalance, takeSnapshot } from "@nomicfoundation/hardhat-network-helpers";

/**
 * Edge-case sweep for the bespoke cross-range allocation / preview / swap math. For a matrix of
 * deposit ratios (all-token0, all-token1, balanced, skewed, tiny, large) and range geometries
 * (symmetric + asymmetric upwardBias) it asserts the invariants that must hold in ALL cases:
 *   1. previewRebalance is strictly ONE-SIDED  (need0*need1 == 0 and surplus0*surplus1 == 0)
 *   2. deficit ⟺ surplus on the opposite token (never both, never mismatched)
 *   3. rebalance never reverts and the binding (deficit) token is ~fully deployed
 *   4. rebalanceViaSwap lands the pot balanced (idle of the surplus side collapses to ~0)
 *
 *   npx hardhat test test/stratus/edge-cases.fork.test.ts --config hardhat.config.stratus.ts
 */
const CL_FACTORY = "0x7Ca1dCCFB4f49564b8f13E18a67747fd428F1C40";
const POOL = "0xb1BC4B830FCbA2184B92e15b9133c41160518038"; // wS/USDC.e ts=8
const wS = "0x039e2fB66102314Ce7b64Ce5Ce3E5183bc94aD38"; // token0 (18d)
const USDCe = "0x29219dd400f2Bf60E5a23d13Be72B486D4038894"; // token1 (6d)
const TICK_SPACING = 8;

const ERC20 = [
  "function transfer(address,uint256) returns (bool)",
  "function approve(address,uint256) returns (bool)",
  "function balanceOf(address) view returns (uint256)",
];

async function fundFromPool(token: string, to: string, amount: bigint) {
  if (amount === 0n) return;
  await impersonateAccount(POOL);
  await setBalance(POOL, ethers.parseEther("100"));
  const s = await ethers.getSigner(POOL);
  await new ethers.Contract(token, ERC20, s).transfer(to, amount);
}

describe("cross-range allocation edge cases (Thick ALPT, Sonic fork)", () => {
  let owner: any, user: any, keeper: any, vfac: any, v: any, vAddr: string;

  async function deployVault(bias: number) {
    const tm = await (await ethers.getContractFactory("TickMath")).deploy();
    const la = await (await ethers.getContractFactory("LiquidityAmounts")).deploy();
    const ph = await (await ethers.getContractFactory("UniswapV3PriceHelper", { libraries: { TickMath: await tm.getAddress() } })).deploy();
    const F = await ethers.getContractFactory("StratusThickVaultFactory", {
      libraries: { TickMath: await tm.getAddress(), LiquidityAmounts: await la.getAddress(), UniswapV3PriceHelper: await ph.getAddress() },
    });
    vfac = await F.connect(owner).deploy(CL_FACTORY);
    await vfac.waitForDeployment();
    const seed0 = ethers.parseEther("1"), seed1 = ethers.parseUnits("0.03", 6);
    await fundFromPool(wS, owner.address, seed0);
    await fundFromPool(USDCe, owner.address, seed1);
    await new ethers.Contract(wS, ERC20, owner).approve(await vfac.getAddress(), seed0);
    await new ethers.Contract(USDCe, ERC20, owner).approve(await vfac.getAddress(), seed1);
    await vfac.createVault(USDCe, wS, TICK_SPACING, bias, 5, seed0, seed1);
    v = await ethers.getContractAt("StratusThickVault", await vfac.vaultForPool(POOL));
    vAddr = await v.getAddress();
    // generous deviation cap, 80% min-skew gate (the sole anti-drain bound; no time cooldown)
    await vfac.setVaultRebalanceParams(vAddr, 500, 10, 200, 8000);
  }

  before(async () => {
    [owner, user, keeper] = await ethers.getSigners();
  });

  // Core per-scenario invariant checks.
  async function checkInvariants(dep0: bigint, dep1: bigint, label: string) {
    await fundFromPool(wS, user.address, dep0);
    await fundFromPool(USDCe, user.address, dep1);
    if (dep0 > 0n) await new ethers.Contract(wS, ERC20, user).approve(vAddr, dep0);
    if (dep1 > 0n) await new ethers.Contract(USDCe, ERC20, user).approve(vAddr, dep1);
    await v.connect(user).deposit(dep0, dep1, user.address, 0);

    const [t0, t1] = await v.getTotalAmounts();
    const [n0, n1, s0, s1] = await v.previewRebalance();

    // 1. strictly one-sided
    expect(n0 === 0n || n1 === 0n, `${label}: need not one-sided (${n0},${n1})`).to.equal(true);
    expect(s0 === 0n || s1 === 0n, `${label}: surplus not one-sided (${s0},${s1})`).to.equal(true);
    // 2. deficit ⟺ surplus on the opposite side
    if (n1 > 0n) expect(s1, `${label}: need1>0 but surplus1>0`).to.equal(0n);
    if (n0 > 0n) expect(s0, `${label}: need0>0 but surplus0>0`).to.equal(0n);

    // 3. rebalance never reverts; binding (deficit) token ~fully deployed
    await vfac.deployIdleVault(vAddr);
    const idle0 = await new ethers.Contract(wS, ERC20, owner).balanceOf(vAddr);
    const idle1 = await new ethers.Contract(USDCe, ERC20, owner).balanceOf(vAddr);
    // the deficit token (need>0 side) is the binding one → its idle should be a small fraction
    if (n1 > 0n) expect(idle1 * 100n, `${label}: token1 (deficit) not deployed`).to.be.lessThan(t1 + 1n);
    if (n0 > 0n) expect(idle0 * 100n, `${label}: token0 (deficit) not deployed`).to.be.lessThan(t0 + 1n);
    console.log(
      `${label.padEnd(16)} need(${ethers.formatEther(n0)},${ethers.formatUnits(n1, 6)})  ` +
        `surplus(${ethers.formatEther(s0)},${ethers.formatUnits(s1, 6)})  idle(${ethers.formatEther(idle0)},${ethers.formatUnits(idle1, 6)})`
    );
    return { n0, n1, s0, s1 };
  }

  describe("symmetric ranges (upwardBias=100)", () => {
    let snap: any;
    before(async () => {
      await deployVault(100);
      snap = await takeSnapshot();
    });
    afterEach(async () => {
      await snap.restore();
    });

    it("all token0 (extreme token1 deficit)", async () => {
      const { n1, s0 } = await checkInvariants(ethers.parseEther("20"), 0n, "all-token0");
      expect(n1).to.be.greaterThan(0n);
      expect(s0).to.be.greaterThan(0n);
    });

    it("all token1 (extreme token0 deficit)", async () => {
      const { n0, s1 } = await checkInvariants(0n, ethers.parseUnits("1", 6), "all-token1");
      expect(n0).to.be.greaterThan(0n);
      expect(s1).to.be.greaterThan(0n);
    });

    it("skewed token0-heavy", async () => {
      await checkInvariants(ethers.parseEther("10"), ethers.parseUnits("0.02", 6), "skew-token0");
    });

    it("skewed token1-heavy", async () => {
      await checkInvariants(ethers.parseEther("0.2"), ethers.parseUnits("1", 6), "skew-token1");
    });

    it("roughly balanced (deposit near the spot ratio)", async () => {
      const pool = await ethers.getContractAt("IThickV3Pool", POOL);
      const sqrtP = BigInt((await pool.slot0())[0]);
      const pSpot = (sqrtP * sqrtP * 10n ** 18n) / (1n << 192n); // USDC-raw per wS-raw, 1e18
      const dep0 = ethers.parseEther("20");
      const dep1 = (dep0 * pSpot) / 10n ** 18n; // ~equal value → near the ranges' wanted ratio
      await checkInvariants(dep0, dep1, "balanced");
    });

    it("tiny amounts", async () => {
      await checkInvariants(ethers.parseEther("0.01"), ethers.parseUnits("0.0005", 6), "tiny");
    });

    it("large amounts", async () => {
      await checkInvariants(ethers.parseEther("200"), ethers.parseUnits("3", 6), "large");
    });

    it("swap-rebalance lands the pot balanced (skewed → idle collapses)", async () => {
      await fundFromPool(wS, user.address, ethers.parseEther("15"));
      await new ethers.Contract(wS, ERC20, user).approve(vAddr, ethers.parseEther("15"));
      await v.connect(user).deposit(ethers.parseEther("15"), 0n, user.address, 0);

      const [, , surplus0] = await v.previewRebalance();
      const [provides1, quoteIn] = await v.previewRebalanceSwap();
      expect(provides1).to.equal(true);

      const budget = quoteIn * 2n;
      await fundFromPool(USDCe, keeper.address, budget);
      await new ethers.Contract(USDCe, ERC20, keeper).approve(vAddr, budget);
      await v.connect(keeper).rebalanceViaSwap(budget, 0n);

      const idle0 = await new ethers.Contract(wS, ERC20, owner).balanceOf(vAddr);
      console.log("swap: surplus", ethers.formatEther(surplus0), "wS -> idle", ethers.formatEther(idle0), "wS");
      // the surplus collapsed: the swap took ~half and the pot deployed the rest
      expect(idle0 * 20n).to.be.lessThan(surplus0); // < 5% of the original surplus remains
    });

    it("anti-drain: a near-balanced pot reverts NotSkewed", async () => {
      // deposit matched to the spot value ratio → pot ~50/50, below the 80% skew gate
      const pool = await ethers.getContractAt("IThickV3Pool", POOL);
      const sqrtP = BigInt((await pool.slot0())[0]);
      const pSpot = (sqrtP * sqrtP * 10n ** 18n) / (1n << 192n);
      const dep0 = ethers.parseEther("20");
      const dep1 = (dep0 * pSpot) / 10n ** 18n;
      await fundFromPool(wS, user.address, dep0);
      await fundFromPool(USDCe, user.address, dep1);
      await new ethers.Contract(wS, ERC20, user).approve(vAddr, dep0);
      await new ethers.Contract(USDCe, ERC20, user).approve(vAddr, dep1);
      await v.connect(user).deposit(dep0, dep1, user.address, 0);

      await fundFromPool(USDCe, keeper.address, ethers.parseUnits("1", 6));
      await new ethers.Contract(USDCe, ERC20, keeper).approve(vAddr, ethers.parseUnits("1", 6));
      await expect(
        v.connect(keeper).rebalanceViaSwap(ethers.parseUnits("1", 6), 0n)
      ).to.be.revertedWithCustomError(v, "NotSkewed");
      console.log("near-balanced pot: rebalanceViaSwap reverted (NotSkewed) ✓");
    });
  });

  describe("asymmetric ranges", () => {
    it("upwardBias=50 stays one-sided + deploys (token0-heavy)", async () => {
      await deployVault(50);
      await checkInvariants(ethers.parseEther("10"), ethers.parseUnits("0.02", 6), "bias50-skew0");
    });

    it("upwardBias=200 stays one-sided + deploys (token1-heavy)", async () => {
      await deployVault(200);
      await checkInvariants(ethers.parseEther("0.2"), ethers.parseUnits("1", 6), "bias200-skew1");
    });
  });
});
