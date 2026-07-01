import { ethers } from "hardhat";
import { expect } from "chai";
import { impersonateAccount, setBalance } from "@nomicfoundation/hardhat-network-helpers";

/**
 * Regression test for the live incident: a permissionless collectGaugeRewards() call landed
 * while a vault's real totalSupply was tiny (just the locked seed shares — no depositor had
 * ever joined), so _distributeReward's `net * 1e18 / totalSupply()` blew rewardPerShareStored
 * up by an unbounded factor. On the live vault (0x096245c02268dceC8Ae96331EEc43eAF6cD1e8EA,
 * Sonic mainnet) this produced rewardPerShareStored ~8.3e29 from a perfectly ordinary 0.00083
 * SHADOW harvest. No funds were at risk there (100% of supply sat at the unspendable DEAD
 * address), but the same accumulator feeds _settleRewards' `bal * (acc - paid)` on every
 * transfer/deposit/withdraw — for a real holder with a large, stale-checkpointed balance that
 * multiplication can exceed uint256 and revert, permanently bricking their withdraw().
 *
 * Two fixes (StratusVaultBase.sol): (1) _distributeReward now divides by
 * `totalSupply() + VIRTUAL_SHARES`, flooring the denominator so a near-empty vault can't
 * produce an unbounded spike; (2) _settleRewards/pendingReward now use Math.mulDiv instead of
 * raw `*`/`/`, so even if the accumulator IS extreme, the multiply-then-divide never reverts
 * as long as the final (divided) result fits in uint256 — which it always will for any
 * realistic token supply.
 *
 *   npx hardhat test test/stratus/reward-accumulator-floor.fork.test.ts --config hardhat.config.stratus.ts
 */
const VOTER = "0x9F59398D0a397b2EEB8a6123a6c7295cB0b0062D";
const POOL = "0x324963c267C354c7660Ce8CA3F5f167E05649970"; // wS/USDC.e ts=50 (gauged)
const wS = "0x039e2fB66102314Ce7b64Ce5Ce3E5183bc94aD38"; // token0 (18d)
const USDCe = "0x29219dd400f2Bf60E5a23d13Be72B486D4038894"; // token1 (6d)
const TICK_SPACING = 50;

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

describe("reward accumulator floor (live-incident regression, Sonic fork)", () => {
  it("a tiny-supply harvest stays bounded, and an extreme accumulator never bricks a large holder's claim", async () => {
    const [owner, user] = await ethers.getSigners();

    const mockToken = await (await ethers.getContractFactory("MockERC20")).deploy("Mock Reward", "MOCK");
    await mockToken.waitForDeployment();
    const mockTokenAddr = await mockToken.getAddress();

    const mockGauge = await (await ethers.getContractFactory("MockGauge")).deploy(mockTokenAddr, 0n);
    await mockGauge.waitForDeployment();
    const mockGaugeAddr = await mockGauge.getAddress();

    const tm = await (await ethers.getContractFactory("TickMath")).deploy();
    const la = await (await ethers.getContractFactory("LiquidityAmounts")).deploy();
    const ph = await (await ethers.getContractFactory("UniswapV3PriceHelper", { libraries: { TickMath: await tm.getAddress() } })).deploy();
    const F = await ethers.getContractFactory("StratusShadowVaultFactory", { libraries: { TickMath: await tm.getAddress(), LiquidityAmounts: await la.getAddress(), UniswapV3PriceHelper: await ph.getAddress() } });
    const factory = await F.connect(owner).deploy(VOTER, mockTokenAddr);
    await factory.waitForDeployment();
    const factoryAddr = await factory.getAddress();

    const seed0 = ethers.parseEther("1");
    const seed1 = ethers.parseUnits("0.03", 6);
    await fundFromPool(wS, owner.address, seed0);
    await fundFromPool(USDCe, owner.address, seed1);
    await new ethers.Contract(wS, ERC20, owner).approve(factoryAddr, seed0);
    await new ethers.Contract(USDCe, ERC20, owner).approve(factoryAddr, seed1);
    await factory.createVault(USDCe, wS, TICK_SPACING, 100, 5, seed0, seed1);

    const vault = await ethers.getContractAt("StratusShadowVault", await factory.vaultForPool(POOL));
    const vaultAddr = await vault.getAddress();
    await factory.setVaultGauge(vaultAddr, mockGaugeAddr);

    const seedSupply = await vault.totalSupply();
    console.log("totalSupply right after seeding (no real depositor yet):", seedSupply.toString());

    // ---- replicate the live incident: harvest while supply is just the seed floor ----
    const ORDINARY_REWARD = ethers.parseEther("0.00083"); // ~ what actually got harvested live
    await mockGauge.setRewardPerCall(ORDINARY_REWARD);
    await vault.collectGaugeRewards();

    const accAfterTinySupplyHarvest = await vault.rewardPerShareStored(mockTokenAddr);
    console.log("rewardPerShareStored after tiny-supply harvest:", accAfterTinySupplyHarvest.toString());

    // bounded: the live incident produced acc ~ net * 1e15 (raw totalSupply=1000 in the
    // denominator). With the VIRTUAL_SHARES floor, the blow-up factor can never exceed
    // ACC_PRECISION / VIRTUAL_SHARES = 1e18 / 1e6 = 1e12, regardless of how small real
    // supply is.
    const harvestedNet = ORDINARY_REWARD * 3n; // 3 ranges
    const VIRTUAL_SHARES = 1_000_000n;
    const ACC_PRECISION = 10n ** 18n;
    const maxPossibleAcc = (harvestedNet * ACC_PRECISION) / VIRTUAL_SHARES;
    expect(accAfterTinySupplyHarvest).to.be.lessThanOrEqual(maxPossibleAcc);
    console.log("bounded by the VIRTUAL_SHARES floor: acc <=", maxPossibleAcc.toString(), "✓");

    // ---- now a real, large depositor joins (checkpointed at the current, already-bounded acc) ----
    const dep0 = ethers.parseEther("50");
    const dep1 = ethers.parseUnits("1.5", 6);
    await fundFromPool(wS, user.address, dep0);
    await fundFromPool(USDCe, user.address, dep1);
    await new ethers.Contract(wS, ERC20, user).approve(vaultAddr, dep0);
    await new ethers.Contract(USDCe, ERC20, user).approve(vaultAddr, dep1);
    await vault.connect(user).deposit(dep0, dep1, user.address, 0);
    const userBal = await vault.balanceOf(user.address);
    expect(await vault.userRewardPerSharePaid(mockTokenAddr, user.address)).to.equal(accAfterTinySupplyHarvest);

    // ---- force an EXTREME accumulator value via one more (mocked) harvest, simulating the
    //      worst case this bug could compound to over time. This deliberately pushes
    //      bal * (acc - paid) past type(uint256).max to prove mulDiv survives where the old
    //      raw `*` would have reverted. ----
    await mockGauge.setRewardPerCall(10n ** 60n);
    await vault.connect(user).collectGaugeRewards();

    const accExtreme = await vault.rewardPerShareStored(mockTokenAddr);
    const paid = await vault.userRewardPerSharePaid(mockTokenAddr, user.address);
    const naiveProduct = userBal * (accExtreme - paid); // what the OLD code computed before /ACC_PRECISION
    console.log("userBal:", userBal.toString());
    console.log("acc delta:", (accExtreme - paid).toString());
    console.log("naive bal*(acc-paid):", naiveProduct.toString(), " > uint256 max?", naiveProduct > 2n ** 256n - 1n);
    expect(naiveProduct).to.be.greaterThan(2n ** 256n - 1n); // confirms this scenario WOULD have overflowed pre-fix

    const expectedPending = await vault.pendingReward(user.address, mockTokenAddr);
    expect(expectedPending).to.be.greaterThan(0n);

    // the critical assertion: claiming does NOT revert, even though the raw product overflows.
    const before = await mockToken.balanceOf(user.address);
    await expect(vault.connect(user).claimRewards()).to.not.be.reverted;
    const after = await mockToken.balanceOf(user.address);
    expect(after - before).to.equal(expectedPending);
    console.log("claimRewards() succeeded despite an overflow-triggering accumulator ✓ (mulDiv fix holds)");

    // and the vault remains fully usable afterward — withdraw doesn't revert either.
    await expect(vault.connect(user).withdraw(userBal, user.address, 0, 0)).to.not.be.reverted;
    console.log("withdraw() after the extreme accumulator: succeeded ✓ (no fund-lock)");
  });
});
