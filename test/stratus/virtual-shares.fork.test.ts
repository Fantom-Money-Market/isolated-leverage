import { ethers } from "hardhat";
import { expect } from "chai";
import { impersonateAccount, setBalance } from "@nomicfoundation/hardhat-network-helpers";

/**
 * Validates the ERC4626 virtual-shares model end-to-end on a Sonic fork:
 *  - sane share scale (1 whole ALPT ~ 1 token1 of value; pricePerShareSafe ~ $1)
 *  - deposit/withdraw round-trip (vector #3)
 *
 *   npx hardhat test test/stratus/virtual-shares.fork.test.ts --config hardhat.config.stratus.ts
 */
const VOTER = "0x9F59398D0a397b2EEB8a6123a6c7295cB0b0062D";
const SHADOW = "0x3333b97138D4b086720b5aE8A7844b1345a33333";
const POOL = "0x324963c267C354c7660Ce8CA3F5f167E05649970"; // USDC.e/wS, the pool funds the test
const USDCe = "0x29219dd400f2Bf60E5a23d13Be72B486D4038894";
const wS = "0x039e2fB66102314Ce7b64Ce5Ce3E5183bc94aD38";
const DEAD = "0x000000000000000000000000000000000000dEaD";
const TICK_SPACING = 50;

const ERC20 = [
  "function transfer(address,uint256) returns (bool)",
  "function approve(address,uint256) returns (bool)",
  "function balanceOf(address) view returns (uint256)",
];

async function fundFromPool(tokenAddr: string, to: string, amount: bigint) {
  await impersonateAccount(POOL);
  await setBalance(POOL, ethers.parseEther("10"));
  const signer = await ethers.getSigner(POOL);
  await new ethers.Contract(tokenAddr, ERC20, signer).transfer(to, amount);
}

describe("virtual-shares model (Sonic fork)", () => {
  it("sane scale + deposit/withdraw round-trip", async () => {
    const [owner, user] = await ethers.getSigners();

    const tm = await (await ethers.getContractFactory("TickMath")).deploy();
    const la = await (await ethers.getContractFactory("LiquidityAmounts")).deploy();
    const ph = await (await ethers.getContractFactory("UniswapV3PriceHelper", { libraries: { TickMath: await tm.getAddress() } })).deploy();
    const F = await ethers.getContractFactory("StratusShadowVaultFactory", { libraries: { TickMath: await tm.getAddress(), LiquidityAmounts: await la.getAddress(), UniswapV3PriceHelper: await ph.getAddress() } });
    const factory = await F.connect(owner).deploy(VOTER, SHADOW);
    await factory.waitForDeployment();

    // seed the owner, approve, create vault (seed -> DEAD)
    const seed0 = ethers.parseEther("1");
    const seed1 = ethers.parseUnits("0.03", 6);
    await fundFromPool(wS, owner.address, seed0);
    await fundFromPool(USDCe, owner.address, seed1);
    await new ethers.Contract(wS, ERC20, owner).approve(await factory.getAddress(), seed0);
    await new ethers.Contract(USDCe, ERC20, owner).approve(await factory.getAddress(), seed1);
    await factory.createVault(USDCe, wS, TICK_SPACING, 100, 5, seed0, seed1);

    const v = await ethers.getContractAt("StratusShadowVault", await factory.vaultForPool(POOL));

    // ---- sane scale ----
    const dec = await v.decimals();
    const pps = await v.pricePerShareSafe();
    const deadShares = await v.balanceOf(DEAD);
    console.log("decimals          :", dec.toString(), "(USDC 6 + offset 6)");
    console.log("pricePerShareSafe :", pps.toString(), "USDC-raw per whole ALPT (~$" + (Number(pps) / 1e6).toFixed(4) + ")");
    console.log("seed @ DEAD       :", deadShares.toString(), "(~" + (Number(deadShares) / 10 ** Number(dec)).toFixed(6) + " ALPT)");
    expect(dec).to.equal(12n);
    expect(pps).to.be.greaterThan(800000n); // ~$0.8  (vs the old ~5e19)
    expect(pps).to.be.lessThan(1200000n);   // ~$1.2
    expect(deadShares).to.be.greaterThan(0n);

    // reward-token subset: only SHADOW, not the gauge's full six-token menu
    const rts = await v.rewardTokensList();
    console.log("rewardTokens      :", rts.length, "->", rts[0]);
    expect(rts.length).to.equal(1);
    expect(rts[0]).to.equal(SHADOW);

    // ---- user deposit ----
    const u0 = ethers.parseEther("2");
    const u1 = ethers.parseUnits("0.06", 6);
    await fundFromPool(wS, user.address, u0);
    await fundFromPool(USDCe, user.address, u1);
    await new ethers.Contract(wS, ERC20, user).approve(await v.getAddress(), u0);
    await new ethers.Contract(USDCe, ERC20, user).approve(await v.getAddress(), u1);
    await v.connect(user).deposit(u0, u1, user.address, 0);

    const userShares = await v.balanceOf(user.address);
    console.log("user shares       :", userShares.toString(), "(~" + (Number(userShares) / 10 ** Number(dec)).toFixed(4) + " ALPT)");
    expect(userShares).to.be.greaterThan(0n);

    // ---- #5: rebalance leaks no value (swap-free; idle redeployed, leftover stays counted) ----
    const valBefore = await v.getTotalValueSafe();
    await factory.deployIdleVault(await v.getAddress()); // deploy the idle deposit
    const valAfter = await v.getTotalValueSafe();
    const diff = valAfter > valBefore ? valAfter - valBefore : valBefore - valAfter;
    const driftBps = valBefore === 0n ? 0n : (diff * 10000n) / valBefore;
    console.log("rebalance value   :", valBefore.toString(), "->", valAfter.toString(), "(drift", driftBps.toString(), "bps)");
    expect(driftBps).to.be.lessThan(50n); // <0.5%: only rounding dust, no leak

    // ---- user withdraw ----
    const usdc = new ethers.Contract(USDCe, ERC20, user);
    const wst = new ethers.Contract(wS, ERC20, user);
    const u0b = await wst.balanceOf(user.address);
    const u1b = await usdc.balanceOf(user.address);
    await v.connect(user).withdraw(userShares, user.address, 0, 0);
    expect(await v.balanceOf(user.address)).to.equal(0n);
    const got0 = (await wst.balanceOf(user.address)) - u0b;
    const got1 = (await usdc.balanceOf(user.address)) - u1b;
    console.log("withdrew          :", got0.toString(), "wS,", got1.toString(), "USDC");
    expect(got0 + got1).to.be.greaterThan(0n);
  });
});
