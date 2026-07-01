import { ethers } from "hardhat";
import { expect } from "chai";
import { impersonateAccount, setBalance } from "@nomicfoundation/hardhat-network-helpers";

/**
 * Validates StratusBeetsV3Adapter on a Sonic fork against the live Beets v3 "Liquid
 * Alignment" stS-wS pool. Proves the standardization claim for Balancer:
 *   - a Beets BPT (already a fungible ERC20) becomes Tarot-priceable via a 1:1 wrapper
 *   - getTotalValueSafe / pricePerShareSafe come from rate providers, and MATCH the pool's
 *     own canonical getRate() (the manipulation-resistant fair value) — not spot reserves
 *   - donation-immune (inflation defense): dumping BPT on the adapter doesn't move the price
 *   - 1:1 wrap/unwrap round-trip
 *
 *   npx hardhat test test/stratus/beets-adapter.fork.test.ts --config hardhat.config.stratus.ts
 */
const VAULT = "0xbA1333333333a1BA1108E8412f11850A5C319bA9"; // Beets v3 Vault
const BPT = "0x75b000584a7d86fb3ef5e15ba26f4c52b41be0e9";  // stS-wS pool token
const HOLDER = "0xaE647ea922D392cC825c51967382940A30893f6D"; // big BPT holder (gauge)
const stS = "0xE5DA20F15420aD15DE0fa650600aFc998bbE3955";   // token1, WITH_RATE

const ERC20 = [
  "function transfer(address,uint256) returns (bool)",
  "function approve(address,uint256) returns (bool)",
  "function balanceOf(address) view returns (uint256)",
];

describe("StratusBeetsV3Adapter (Sonic fork)", () => {
  it("rate-provider valuation matches getRate, donation-immune, 1:1 round-trip", async () => {
    const [user] = await ethers.getSigners();

    const A = await ethers.getContractFactory("StratusBeetsV3Adapter");
    const adapter = await A.deploy(VAULT, BPT, "Stratus Beets stS-wS", "s-stS-wS");
    await adapter.waitForDeployment();
    const adapterAddr = await adapter.getAddress();

    // fund the user with BPT from the big holder
    await impersonateAccount(HOLDER);
    await setBalance(HOLDER, ethers.parseEther("10"));
    const holder = await ethers.getSigner(HOLDER);
    const amount = ethers.parseEther("1000");
    await new ethers.Contract(BPT, ERC20, holder).transfer(user.address, amount);

    // ---- wrap 1:1 ----
    await new ethers.Contract(BPT, ERC20, user).approve(adapterAddr, amount);
    await adapter.wrap(amount, user.address);
    expect(await adapter.balanceOf(user.address)).to.equal(amount);
    expect(await adapter.totalSupply()).to.equal(amount);

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

    // twapPrice = wS in stS = 1/stSrate; stS rate ~1.07 so ~0.93
    expect(twap).to.be.greaterThan(ethers.parseEther("0.85"));
    expect(twap).to.be.lessThan(ethers.parseEther("1.0"));

    // ---- cross-check vs canonical fair value: BPT price in stS = pool.getRate / stS.getRate
    const bptRateInS = await new ethers.Contract(BPT, ["function getRate() view returns (uint256)"], user).getRate();
    const stSRate = await new ethers.Contract(stS, ["function getRate() view returns (uint256)"], user).getRate();
    const bptInStS = (BigInt(bptRateInS) * 10n ** 18n) / BigInt(stSRate);
    console.log("getRate cross-chk :", ethers.formatEther(bptInStS), "stS per BPT (independent)");
    const diffBps = (pps > bptInStS ? pps - bptInStS : bptInStS - pps) * 10000n / bptInStS;
    console.log("pps vs getRate    : drift", diffBps.toString(), "bps");
    expect(diffBps).to.be.lessThan(100n); // <1% — valuation IS the rate-based fair value

    // consistency: getTotalValueSafe ≈ pps * supply / 1e18 (rounding dust only)
    const recon = (pps * amount) / 10n ** 18n;
    const reconDiff = tvs > recon ? tvs - recon : recon - tvs;
    expect(reconDiff).to.be.lessThan(10n ** 12n);

    // ---- donation immunity (inflation defense): dump BPT on the adapter, price unchanged ----
    await new ethers.Contract(BPT, ERC20, holder).transfer(adapterAddr, ethers.parseEther("500"));
    const ppsAfter = await adapter.pricePerShareSafe();
    console.log("pps after 500 BPT donation:", ethers.formatEther(ppsAfter), "(must be unchanged)");
    expect(ppsAfter).to.equal(pps);

    // ---- 1:1 unwrap round-trip ----
    const bptBefore = await new ethers.Contract(BPT, ERC20, user).balanceOf(user.address);
    await adapter.unwrap(amount, user.address);
    expect(await adapter.balanceOf(user.address)).to.equal(0n);
    const got = (await new ethers.Contract(BPT, ERC20, user).balanceOf(user.address)) - bptBefore;
    console.log("unwrapped         :", ethers.formatEther(got), "BPT (1:1)");
    expect(got).to.equal(amount);
  });
});
