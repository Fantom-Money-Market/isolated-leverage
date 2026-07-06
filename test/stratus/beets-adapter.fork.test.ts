import { ethers } from "hardhat";
import { expect } from "chai";
import { impersonateAccount, setBalance, time } from "@nomicfoundation/hardhat-network-helpers";

/**
 * Validates StratusBeetsV3Adapter on a Sonic fork against the live Beets v3 "Liquid
 * Alignment" stS-wS pool. Proves the standardization claim for Balancer:
 *   - a Beets BPT (already a fungible ERC20) becomes Tarot-priceable via a 1:1 wrapper
 *   - getTotalValueSafe / pricePerShareSafe come from rate providers, and MATCH the pool's
 *     own canonical getRate() (the manipulation-resistant fair value) — not spot reserves
 *   - donation-immune (inflation defense): dumping BPT on the adapter doesn't move the price
 *   - 1:1 wrap/unwrap round-trip with gauge auto-stake
 *   - gauge emissions harvest + claim for wrapped holders
 *
 *   npx hardhat test test/stratus/beets-adapter.fork.test.ts --config hardhat.config.stratus.ts
 */
const VAULT = "0xbA1333333333a1BA1108E8412f11850A5C319bA9"; // Beets v3 Vault
const BPT = "0x75b000584a7d86fb3ef5e15ba26f4c52b41be0e9";  // stS-wS pool token
const GAUGE = "0xaE647ea922D392cC825c51967382940A30893f6D"; // stS-wS Curve-style gauge
const BEETS = "0x2D0E0814E62D80056181F5cd932274405966e4f0";
const stS = "0xE5DA20F15420aD15DE0fa650600aFc998bbE3955";   // token1, WITH_RATE
// Gauge custody holds the staked BPT; impersonate on fork to fund the test user.
const BPT_SOURCE = GAUGE;

const ERC20 = [
  "function transfer(address,uint256) returns (bool)",
  "function approve(address,uint256) returns (bool)",
  "function balanceOf(address) view returns (uint256)",
];

describe("StratusBeetsV3Adapter (Sonic fork)", () => {
  it("rate-provider valuation matches getRate, donation-immune, 1:1 round-trip", async () => {
    const [user] = await ethers.getSigners();

    const A = await ethers.getContractFactory("StratusBeetsV3Adapter");
    const adapter = await A.deploy(VAULT, BPT, GAUGE, "Stratus Beets stS-wS", "s-stS-wS");
    await adapter.waitForDeployment();
    const adapterAddr = await adapter.getAddress();
    expect(await adapter.gauge()).to.equal(GAUGE);

    await adapter.setRewardTokens([BEETS, stS]);

    await impersonateAccount(BPT_SOURCE);
    await setBalance(BPT_SOURCE, ethers.parseEther("10"));
    const holder = await ethers.getSigner(BPT_SOURCE);
    const amount = ethers.parseEther("1000");
    await new ethers.Contract(BPT, ERC20, holder).transfer(user.address, amount);

    // ---- wrap 1:1 (auto-stakes in gauge) ----
    await new ethers.Contract(BPT, ERC20, user).approve(adapterAddr, amount);
    await adapter.wrap(amount, user.address);
    expect(await adapter.balanceOf(user.address)).to.equal(amount);
    expect(await adapter.totalSupply()).to.equal(amount);
    expect(await new ethers.Contract(BPT, ERC20, user).balanceOf(adapterAddr)).to.equal(0n);
    expect(await new ethers.Contract(GAUGE, ERC20, user).balanceOf(adapterAddr)).to.equal(amount);

    const dec = await adapter.decimals();
    const pps = await adapter.pricePerShareSafe();
    const twap = await adapter.twapPrice();
    const tvs = await adapter.getTotalValueSafe();
    const [t0, t1] = await adapter.getTotalAmounts();
    console.log("decimals          :", dec.toString());
    console.log("twapPrice(wS in stS):", ethers.formatEther(twap));
    console.log("pricePerShareSafe :", ethers.formatEther(pps), "stS per BPT");
    console.log("getTotalValueSafe :", ethers.formatEther(tvs), "stS for 1000 BPT");
    console.log("share of reserves :", ethers.formatEther(t0), "wS +", ethers.formatEther(t1), "stS");
    expect(dec).to.equal(18n);

    expect(twap).to.be.greaterThan(ethers.parseEther("0.85"));
    expect(twap).to.be.lessThan(ethers.parseEther("1.0"));

    const bptRateInS = await new ethers.Contract(BPT, ["function getRate() view returns (uint256)"], user).getRate();
    const stSRate = await new ethers.Contract(stS, ["function getRate() view returns (uint256)"], user).getRate();
    const bptInStS = (BigInt(bptRateInS) * 10n ** 18n) / BigInt(stSRate);
    console.log("getRate cross-chk :", ethers.formatEther(bptInStS), "stS per BPT (independent)");
    const diffBps = (pps > bptInStS ? pps - bptInStS : bptInStS - pps) * 10000n / bptInStS;
    console.log("pps vs getRate    : drift", diffBps.toString(), "bps");
    expect(diffBps).to.be.lessThan(100n);

    const recon = (pps * amount) / 10n ** 18n;
    const reconDiff = tvs > recon ? tvs - recon : recon - tvs;
    expect(reconDiff).to.be.lessThan(10n ** 12n);

    await new ethers.Contract(BPT, ERC20, holder).transfer(adapterAddr, ethers.parseEther("500"));
    const ppsAfter = await adapter.pricePerShareSafe();
    console.log("pps after 500 BPT donation:", ethers.formatEther(ppsAfter), "(must be unchanged)");
    expect(ppsAfter).to.equal(pps);

    const bptBefore = await new ethers.Contract(BPT, ERC20, user).balanceOf(user.address);
    await adapter.unwrap(amount, user.address);
    expect(await adapter.balanceOf(user.address)).to.equal(0n);
    expect(await new ethers.Contract(GAUGE, ERC20, user).balanceOf(adapterAddr)).to.equal(0n);
    const got = (await new ethers.Contract(BPT, ERC20, user).balanceOf(user.address)) - bptBefore;
    console.log("unwrapped         :", ethers.formatEther(got), "BPT (1:1)");
    expect(got).to.equal(amount);
  });

  it("harvests gauge emissions to wrapped holders", async function () {
    this.timeout(120_000);
    const [user, other] = await ethers.getSigners();

    const adapter = await (
      await ethers.getContractFactory("StratusBeetsV3Adapter")
    ).deploy(VAULT, BPT, GAUGE, "Stratus Beets stS-wS", "s-stS-wS");
    await adapter.waitForDeployment();
    await adapter.setRewardTokens([BEETS, stS]);

    await impersonateAccount(BPT_SOURCE);
    await setBalance(BPT_SOURCE, ethers.parseEther("10"));
    const holder = await ethers.getSigner(BPT_SOURCE);
    const amount = ethers.parseEther("5000");
    await new ethers.Contract(BPT, ERC20, holder).transfer(user.address, amount);
    await new ethers.Contract(BPT, ERC20, user).approve(await adapter.getAddress(), amount);
    await adapter.wrap(amount, user.address);

    const pendingBefore = await adapter.pendingReward(user.address, BEETS);
    console.log("pending BEETS before time:", pendingBefore.toString());

    await time.increase(7 * 24 * 60 * 60);

    const [, harvested] = await adapter.collectGaugeRewards.staticCall();
    const totalHarvested = harvested.reduce((a: bigint, b: bigint) => a + b, 0n);
    console.log(
      "harvested         :",
      harvested.map((h: bigint, i: number) => (i === 0 ? "BEETS" : "stS") + "=" + ethers.formatEther(h)).join(", ")
    );
    expect(totalHarvested).to.be.greaterThan(0n);

    await adapter.collectGaugeRewards();
    const pendingBeets = await adapter.pendingReward(user.address, BEETS);
    const pendingStS = await adapter.pendingReward(user.address, stS);
    console.log("pending BEETS     :", ethers.formatEther(pendingBeets));
    console.log("pending stS       :", ethers.formatEther(pendingStS));
    expect(pendingBeets + pendingStS).to.be.greaterThan(0n);

    const beetsBefore = await new ethers.Contract(BEETS, ERC20, user).balanceOf(user.address);
    const stSBefore = await new ethers.Contract(stS, ERC20, user).balanceOf(user.address);
    await adapter.connect(user).claimRewards();
    const gotBeets = (await new ethers.Contract(BEETS, ERC20, user).balanceOf(user.address)) - beetsBefore;
    const gotStS = (await new ethers.Contract(stS, ERC20, user).balanceOf(user.address)) - stSBefore;
    console.log("claimed BEETS     :", ethers.formatEther(gotBeets));
    console.log("claimed stS       :", ethers.formatEther(gotStS));
    expect(gotBeets + gotStS).to.be.greaterThan(0n);

    // second holder with no shares gets nothing
    expect(await adapter.pendingReward(other.address, BEETS)).to.equal(0n);
  });

  it("raw-token deposit → shares, withdraw → both tokens (lending-stack compatible)", async function () {
    this.timeout(120_000);
    const [user] = await ethers.getSigners();
    const wS = "0x039e2fB66102314Ce7b64Ce5Ce3E5183bc94aD38"; // token0
    const WS_SOURCE = "0x324963c267C354c7660Ce8CA3F5f167E05649970"; // Shadow wS/USDC.e pool

    const adapter = await (
      await ethers.getContractFactory("StratusBeetsV3Adapter")
    ).deploy(VAULT, BPT, GAUGE, "Stratus Beets stS-wS", "s-stS-wS");
    await adapter.waitForDeployment();
    const adapterAddr = await adapter.getAddress();

    // fund user with raw wS only — one-sided deposit is the common UX case and exactly
    // what the LeverageRouter does mid-callback
    await impersonateAccount(WS_SOURCE);
    await setBalance(WS_SOURCE, ethers.parseEther("10"));
    const wsHolder = await ethers.getSigner(WS_SOURCE);
    const depositAmt = ethers.parseEther("1000");
    await new ethers.Contract(wS, ERC20, wsHolder).transfer(user.address, depositAmt);

    // ---- deposit(token0 only) ----
    await new ethers.Contract(wS, ERC20, user).approve(adapterAddr, depositAmt);
    const shares = await adapter.deposit.staticCall(depositAmt, 0, user.address, 0);
    await adapter.deposit(depositAmt, 0, user.address, 0);
    console.log("shares minted     :", ethers.formatEther(shares), "for 1000 wS one-sided");
    expect(shares).to.be.greaterThan(0n);
    expect(await adapter.balanceOf(user.address)).to.equal(shares);
    // 1:1 invariant: every share is backed by a staked BPT
    expect(await new ethers.Contract(GAUGE, ERC20, user).balanceOf(adapterAddr)).to.equal(shares);
    expect(await adapter.totalSupply()).to.equal(shares);

    // value sanity: shares should be worth roughly the deposit (minus unbalanced-add fee).
    // twapPrice = wS in stS; value returned in stS terms.
    const pps = await adapter.pricePerShareSafe();
    const twap = await adapter.twapPrice();
    const valueStS = (pps * shares) / 10n ** 18n;
    const depositValueStS = (depositAmt * twap) / 10n ** 18n;
    const driftBps = ((depositValueStS > valueStS ? depositValueStS - valueStS : valueStS - depositValueStS) * 10000n) / depositValueStS;
    console.log("deposit value     :", ethers.formatEther(depositValueStS), "stS | shares value:", ethers.formatEther(valueStS), "stS | drift", driftBps.toString(), "bps");
    expect(driftBps).to.be.lessThan(200n); // < 2% (swap-fee on the unbalanced portion)

    // ---- withdraw half → BOTH tokens come back (proportional exit) ----
    const stSC = new ethers.Contract(stS, ERC20, user);
    const wSC = new ethers.Contract(wS, ERC20, user);
    const ws0 = await wSC.balanceOf(user.address);
    const sts0 = await stSC.balanceOf(user.address);
    const half = shares / 2n;
    await adapter.withdraw(half, user.address, 0, 0);
    const gotWs = (await wSC.balanceOf(user.address)) - ws0;
    const gotStS = (await stSC.balanceOf(user.address)) - sts0;
    console.log("withdraw half     :", ethers.formatEther(gotWs), "wS +", ethers.formatEther(gotStS), "stS");
    expect(gotWs).to.be.greaterThan(0n);
    expect(gotStS).to.be.greaterThan(0n);
    expect(await adapter.balanceOf(user.address)).to.equal(shares - half);
    expect(await new ethers.Contract(GAUGE, ERC20, user).balanceOf(adapterAddr)).to.equal(shares - half);

    // slippage floor is enforced
    await expect(
      adapter.withdraw(half, user.address, ethers.parseEther("1000000"), 0)
    ).to.be.reverted;
  });
});
