import { ethers } from "hardhat";
import { expect } from "chai";
import { impersonateAccount, setBalance, takeSnapshot } from "@nomicfoundation/hardhat-network-helpers";

/**
 * Validates previewRebalance() against a real rebalance on a Sonic fork:
 *   - with a token0-heavy vault, it reports a token1 deficit (need1) and a token0 surplus
 *   - rebalancing with NO injection leaves exactly the predicted surplus idle
 *   - injecting the predicted need1 deploys the surplus away (the keeper-funded rebalance)
 *
 *   npx hardhat test test/stratus/preview-rebalance.fork.test.ts --config hardhat.config.stratus.ts
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
  await impersonateAccount(POOL);
  await setBalance(POOL, ethers.parseEther("100"));
  const s = await ethers.getSigner(POOL);
  await new ethers.Contract(token, ERC20, s).transfer(to, amount);
}

function relBps(actual: bigint, expected: bigint): bigint {
  if (expected === 0n) return actual === 0n ? 0n : 100000n;
  const d = actual > expected ? actual - expected : expected - actual;
  return (d * 10000n) / expected;
}

describe("previewRebalance (Thick ALPT, Sonic fork)", () => {
  it("predicts surplus/deficit; injecting need deploys with ~no leftover", async () => {
    const [owner, user] = await ethers.getSigners();

    const tm = await (await ethers.getContractFactory("TickMath")).deploy();
    const la = await (await ethers.getContractFactory("LiquidityAmounts")).deploy();
    const ph = await (await ethers.getContractFactory("UniswapV3PriceHelper", { libraries: { TickMath: await tm.getAddress() } })).deploy();
    const F = await ethers.getContractFactory("StratusThickVaultFactory", { libraries: { TickMath: await tm.getAddress(), LiquidityAmounts: await la.getAddress(), UniswapV3PriceHelper: await ph.getAddress() } });
    const factory = await F.connect(owner).deploy(CL_FACTORY);
    await factory.waitForDeployment();
    const seed0 = ethers.parseEther("1");
    const seed1 = ethers.parseUnits("0.03", 6);
    await fundFromPool(wS, owner.address, seed0);
    await fundFromPool(USDCe, owner.address, seed1);
    await new ethers.Contract(wS, ERC20, owner).approve(await factory.getAddress(), seed0);
    await new ethers.Contract(USDCe, ERC20, owner).approve(await factory.getAddress(), seed1);
    await factory.createVault(USDCe, wS, TICK_SPACING, 100, 5, seed0, seed1);
    const v = await ethers.getContractAt("StratusThickVault", await factory.vaultForPool(POOL));

    // deposit token0-heavy so the vault is imbalanced (lots of wS, almost no USDC)
    const dep0 = ethers.parseEther("10");
    const dep1 = ethers.parseUnits("0.01", 6);
    await fundFromPool(wS, user.address, dep0);
    await fundFromPool(USDCe, user.address, dep1);
    await new ethers.Contract(wS, ERC20, user).approve(await v.getAddress(), dep0);
    await new ethers.Contract(USDCe, ERC20, user).approve(await v.getAddress(), dep1);
    await v.connect(user).deposit(dep0, dep1, user.address, 0);

    // ---- preview ----
    const [need0, need1, surplus0, surplus1] = await v.previewRebalance();
    console.log("need0   :", ethers.formatEther(need0), "wS");
    console.log("need1   :", ethers.formatUnits(need1, 6), "USDC");
    console.log("surplus0:", ethers.formatEther(surplus0), "wS");
    console.log("surplus1:", ethers.formatUnits(surplus1, 6), "USDC");
    expect(need0).to.equal(0n); // token0 is the surplus, not the deficit
    expect(need1).to.be.greaterThan(0n); // need token1 (USDC) to balance
    expect(surplus0).to.be.greaterThan(0n); // excess wS that won't deploy

    const snap = await takeSnapshot();

    // ---- Case A: rebalance with NO injection → idle leftover ≈ predicted surplus ----
    await factory.deployIdleVault(await v.getAddress());
    const idle0 = await new ethers.Contract(wS, ERC20, owner).balanceOf(await v.getAddress());
    const idle1 = await new ethers.Contract(USDCe, ERC20, owner).balanceOf(await v.getAddress());
    console.log("actual idle0 after rebalance:", ethers.formatEther(idle0), "wS  (drift", relBps(idle0, surplus0).toString(), "bps)");
    expect(relBps(idle0, surplus0)).to.be.lessThan(200n); // <2% — preview matches reality (0 bps in practice)
    expect(idle1).to.be.lessThan(1000n); // token1 surplus is dust (<0.001 USDC); both predicted & actual ~0

    await snap.restore();

    // ---- Case B: inject the predicted need1, then rebalance → surplus deploys away ----
    await fundFromPool(USDCe, user.address, need1);
    await new ethers.Contract(USDCe, ERC20, user).approve(await v.getAddress(), need1);
    await v.connect(user).deposit(0, need1, user.address, 0); // single-sided deposit of the deficit token
    await factory.deployIdleVault(await v.getAddress());
    const idle0b = await new ethers.Contract(wS, ERC20, owner).balanceOf(await v.getAddress());
    console.log("idle0 after injecting need1 :", ethers.formatEther(idle0b), "wS (was", ethers.formatEther(surplus0), "surplus)");
    expect(idle0b).to.be.lessThan(surplus0 / 5n); // the wS surplus was largely deployed
  });
});
