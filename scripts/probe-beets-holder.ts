import { ethers } from "hardhat";

// Find an address holding the stS-wS BPT to impersonate in the fork test.
//   npx hardhat run scripts/probe-beets-holder.ts --network sonic --config hardhat.config.stratus.ts
const BPT = "0x75b000584a7d86fb3ef5e15ba26f4c52b41be0e9";
const p = ethers.provider;

async function bal(addr: string): Promise<bigint> {
  const iface = new ethers.Interface(["function balanceOf(address) view returns (uint256)"]);
  try {
    const ret = await p.call({ to: BPT, data: iface.encodeFunctionData("balanceOf", [addr]) });
    return BigInt(iface.decodeFunctionResult("balanceOf", ret)[0]);
  } catch {
    return 0n;
  }
}

async function main() {
  // candidate Beets infra + gauges seen on Sonic
  const candidates: Record<string, string> = {
    "LM Gauge 0x9707":      "0x97079f7e04b535fe7cd3f972ce558412dfb33946",
    "maBEETS 0x9736":       "0x973670ce19594f857a7cd85ee834c7a74a941684",
    "VaultV3 0xbA13":       "0xbA1333333333a1BA1108E8412f11850A5C319bA9",
  };
  for (const [name, addr] of Object.entries(candidates)) {
    const b = await bal(addr);
    console.log(name.padEnd(22), addr, "->", ethers.formatUnits(b, 18), "BPT");
  }

  // Scan recent Transfer events to discover a live holder.
  console.log("\nscanning recent Transfer events for holders...");
  const latest = await p.getBlockNumber();
  const topic = ethers.id("Transfer(address,address,uint256)");
  for (let span = 0; span < 5; span++) {
    const to = latest - span * 9000;
    const from = to - 9000;
    try {
      const logs = await p.getLogs({ address: BPT, topics: [topic], fromBlock: from, toBlock: to });
      const holders = new Set<string>();
      for (const l of logs) holders.add(ethers.getAddress("0x" + l.topics[2].slice(26)));
      for (const h of holders) {
        if (h === ethers.ZeroAddress) continue;
        const b = await bal(h);
        if (b > ethers.parseEther("100")) {
          console.log("  holder:", h, "->", ethers.formatUnits(b, 18), "BPT");
        }
      }
      if (logs.length) break;
    } catch (e: any) {
      console.log("  (range", from, "-", to, "err)");
    }
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
