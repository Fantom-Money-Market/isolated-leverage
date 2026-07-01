import { ethers } from "hardhat";
import { expect } from "chai";
import { impersonateAccount, setBalance } from "@nomicfoundation/hardhat-network-helpers";

/**
 * Validates the StratusThickVault adapter end-to-end on a Sonic fork. Thick is a vanilla
 * Uniswap V3 fork (no NFT, no index, no gauge), so this proves the shared base
 * (StratusVaultBase / StratusCLVaultBase) drives a second venue with all the hardening:
 *   - sane share scale (1 whole ALPT ~ 1 token1 of value; pricePerShareSafe ~ $1)
 *   - deposit/withdraw round-trip
 *   - rebalance leaks no value
 *   - reward set stays EMPTY (fee-only venue — no emissions distributed)
 *
 *   npx hardhat test test/stratus/thick.fork.test.ts --config hardhat.config.stratus.ts
 */
const CL_FACTORY = "0x7Ca1dCCFB4f49564b8f13E18a67747fd428F1C40"; // Thick CL factory
const POOL = "0xb1BC4B830FCbA2184B92e15b9133c41160518038"; // wS/USDC.e ts=8, funds the test
const wS = "0x039e2fB66102314Ce7b64Ce5Ce3E5183bc94aD38"; // token0 (18 dec)
const USDCe = "0x29219dd400f2Bf60E5a23d13Be72B486D4038894"; // token1 (6 dec)
const DEAD = "0x000000000000000000000000000000000000dEaD";
const TICK_SPACING = 8;

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

describe("StratusThickVault (Sonic fork)", () => {
  it("sane scale + round-trip + rebalance + empty reward set", async () => {
    const [owner, user] = await ethers.getSigners();

    const tm = await (await ethers.getContractFactory("TickMath")).deploy();
    const la = await (await ethers.getContractFactory("LiquidityAmounts")).deploy();
    const ph = await (await ethers.getContractFactory("UniswapV3PriceHelper", { libraries: { TickMath: await tm.getAddress() } })).deploy();
    const F = await ethers.getContractFactory("StratusThickVaultFactory", { libraries: { TickMath: await tm.getAddress(), LiquidityAmounts: await la.getAddress(), UniswapV3PriceHelper: await ph.getAddress() } });
    const factory = await F.connect(owner).deploy(CL_FACTORY);
    await factory.waitForDeployment();

    // seed the owner, approve, create vault (seed -> DEAD)
    const seed0 = ethers.parseEther("1"); // wS
    const seed1 = ethers.parseUnits("0.03", 6); // USDC.e
    await fundFromPool(wS, owner.address, seed0);
    await fundFromPool(USDCe, owner.address, seed1);
    await new ethers.Contract(wS, ERC20, owner).approve(await factory.getAddress(), seed0);
    await new ethers.Contract(USDCe, ERC20, owner).approve(await factory.getAddress(), seed1);
    await factory.createVault(USDCe, wS, TICK_SPACING, 100, 5, seed0, seed1);

    const v = await ethers.getContractAt("StratusThickVault", await factory.vaultForPool(POOL));

    // ---- sane scale ----
    const dec = await v.decimals();
    const pps = await v.pricePerShareSafe();
    const deadShares = await v.balanceOf(DEAD);
    console.log("decimals          :", dec.toString(), "(USDC 6 + offset 6)");
    console.log("pricePerShareSafe :", pps.toString(), "USDC-raw per whole ALPT (~$" + (Number(pps) / 1e6).toFixed(4) + ")");
    console.log("seed @ DEAD       :", deadShares.toString());
    expect(dec).to.equal(12n);
    expect(pps).to.be.greaterThan(800000n);
    expect(pps).to.be.lessThan(1200000n);
    expect(deadShares).to.be.greaterThan(0n);

    // ---- fee-only venue: no reward tokens registered ----
    const rts = await v.rewardTokensList();
    console.log("rewardTokens      :", rts.length, "(fee-only — expected 0)");
    expect(rts.length).to.equal(0);

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

    // ---- rebalance leaks no value ----
    const valBefore = await v.getTotalValueSafe();
    await factory.deployIdleVault(await v.getAddress());
    const valAfter = await v.getTotalValueSafe();
    const diff = valAfter > valBefore ? valAfter - valBefore : valBefore - valAfter;
    const driftBps = valBefore === 0n ? 0n : (diff * 10000n) / valBefore;
    console.log("rebalance value   :", valBefore.toString(), "->", valAfter.toString(), "(drift", driftBps.toString(), "bps)");
    expect(driftBps).to.be.lessThan(50n);

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
