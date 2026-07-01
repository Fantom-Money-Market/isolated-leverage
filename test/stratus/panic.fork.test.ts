import { ethers } from "hardhat";
import { expect } from "chai";
import { impersonateAccount, setBalance } from "@nomicfoundation/hardhat-network-helpers";

/**
 * Emergency-stop (panicAtTheDisco / resume) behavior:
 *   - deposit(), deployIdle(), and rebalanceViaSwap() all revert with VaultPaused() while paused.
 *   - withdraw() and claimRewards() stay open on purpose — a panic must never trap user funds.
 *   - only the factory contract can trip/lift the pause on a vault (mirrors setGauge etc.).
 *   - the factory's batch panicAtTheDisco([...])/resumeVaults([...]) can flip many vaults at once.
 *
 *   npx hardhat test test/stratus/panic.fork.test.ts --config hardhat.config.stratus.ts
 */
const CL_FACTORY = "0x7Ca1dCCFB4f49564b8f13E18a67747fd428F1C40"; // Thick CL factory
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

describe("panicAtTheDisco / resume (Thick ALPT, Sonic fork)", () => {
  it("pauses deposit/deployIdle/rebalanceViaSwap; withdraw stays open; only the factory can toggle it", async () => {
    const [owner, user] = await ethers.getSigners();

    const tm = await (await ethers.getContractFactory("TickMath")).deploy();
    const la = await (await ethers.getContractFactory("LiquidityAmounts")).deploy();
    const ph = await (await ethers.getContractFactory("UniswapV3PriceHelper", { libraries: { TickMath: await tm.getAddress() } })).deploy();
    const F = await ethers.getContractFactory("StratusThickVaultFactory", {
      libraries: { TickMath: await tm.getAddress(), LiquidityAmounts: await la.getAddress(), UniswapV3PriceHelper: await ph.getAddress() },
    });
    const factory = await F.connect(owner).deploy(CL_FACTORY);
    await factory.waitForDeployment();
    const factoryAddr = await factory.getAddress();

    const seed0 = ethers.parseEther("1");
    const seed1 = ethers.parseUnits("0.03", 6);
    await fundFromPool(wS, owner.address, seed0);
    await fundFromPool(USDCe, owner.address, seed1);
    await new ethers.Contract(wS, ERC20, owner).approve(factoryAddr, seed0);
    await new ethers.Contract(USDCe, ERC20, owner).approve(factoryAddr, seed1);
    await factory.createVault(USDCe, wS, TICK_SPACING, 100, 5, seed0, seed1);
    const vault = await ethers.getContractAt("StratusThickVault", await factory.vaultForPool(POOL));
    const vaultAddr = await vault.getAddress();

    expect(await vault.paused()).to.equal(false);

    // sanity: deposit works while unpaused
    const dep0 = ethers.parseEther("1");
    const dep1 = ethers.parseUnits("0.03", 6);
    await fundFromPool(wS, user.address, dep0 * 2n);
    await fundFromPool(USDCe, user.address, dep1 * 2n);
    await new ethers.Contract(wS, ERC20, user).approve(vaultAddr, dep0 * 2n);
    await new ethers.Contract(USDCe, ERC20, user).approve(vaultAddr, dep1 * 2n);
    await vault.connect(user).deposit(dep0, dep1, user.address, 0);

    // a random EOA cannot pause a vault directly — only the factory contract can.
    await expect(vault.connect(user).panicAtTheDisco()).to.be.revertedWithCustomError(vault, "Unauthorized");

    // owner trips the panic button across a batch (just this one vault here).
    await factory.connect(owner).panicAtTheDisco([vaultAddr]);
    expect(await vault.paused()).to.equal(true);

    await expect(vault.connect(user).deposit(dep0, dep1, user.address, 0)).to.be.revertedWithCustomError(
      vault,
      "VaultPaused"
    );
    await expect(factory.connect(owner).deployIdleVault(vaultAddr)).to.be.revertedWithCustomError(vault, "VaultPaused");
    await expect(vault.connect(user).rebalanceViaSwap(0, 0)).to.be.revertedWithCustomError(vault, "VaultPaused");

    // withdrawals stay open even while paused — the whole point of a panic button is it can
    // never be used to trap funds.
    const shares = await vault.balanceOf(user.address);
    await expect(vault.connect(user).withdraw(shares, user.address, 0, 0)).to.not.be.reverted;
    expect(await vault.balanceOf(user.address)).to.equal(0n);

    // a non-owner can't call the factory's panic/resume either.
    await expect(factory.connect(user).resumeVaults([vaultAddr])).to.be.reverted;

    // resume lifts it.
    await factory.connect(owner).resumeVaults([vaultAddr]);
    expect(await vault.paused()).to.equal(false);
    await fundFromPool(wS, user.address, dep0);
    await fundFromPool(USDCe, user.address, dep1);
    await new ethers.Contract(wS, ERC20, user).approve(vaultAddr, dep0);
    await new ethers.Contract(USDCe, ERC20, user).approve(vaultAddr, dep1);
    await expect(vault.connect(user).deposit(dep0, dep1, user.address, 0)).to.not.be.reverted;
  });
});
