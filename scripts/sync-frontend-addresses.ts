import * as fs from "fs";
import * as path from "path";

// Rewrites the hardcoded fork addresses in the frontend's config/contracts.ts from the
// fork-ui/*.json files the deploy scripts emit.
//
// Every fork redeploy (and every `hardhat_reset`) moves all four markets, and keeping the
// frontend in sync by hand is how a market silently ends up pointing at an address with no
// code — which surfaces as an undecodable read deep in a hook rather than as "stale config".
//
//   npx ts-node scripts/sync-frontend-addresses.ts
//   (or: npx hardhat run scripts/sync-frontend-addresses.ts --network localhost --config hardhat.config.fork-ui.ts)

const FRONTEND = process.env.FRONTEND_DIR || path.join(__dirname, "..", "..", "fmoneyv3-frontend");
const TARGET = path.join(FRONTEND, "config", "contracts.ts");

/** Which fork-ui config feeds which key, per deployment block in contracts.ts. */
const BLOCKS: { block: string; cfg: string; keys: string[] }[] = [
  {
    block: "deployments",
    cfg: "config.json",
    keys: ["vault", "collateral", "borrowable0", "borrowable1", "leverageRouter", "unwindRouter", "marketLens", "poolSwapHelper"],
  },
  {
    block: "beetsDeployments",
    cfg: "beets-config.json",
    keys: ["adapter", "vault", "collateral", "borrowable0", "borrowable1", "leverageRouter", "unwindRouter"],
  },
  {
    block: "thickDeployments",
    cfg: "thick-config.json",
    keys: ["vault", "collateral", "borrowable0", "borrowable1", "leverageRouter", "unwindRouter"],
  },
  {
    block: "dlmmDeployments",
    cfg: "dlmm-config.json",
    keys: ["vault", "collateral", "borrowable0", "borrowable1", "leverageRouter", "unwindRouter", "factory", "pair", "hook"],
  },
];

function blockBounds(src: string, name: string): [number, number] | null {
  const start = src.indexOf(`export const ${name}`);
  if (start < 0) return null;
  // The block ends at the first line that is exactly "};" at column 0 after the start.
  const end = src.indexOf("\n};", start);
  return end < 0 ? null : [start, end + 3];
}

function main() {
  if (!fs.existsSync(TARGET)) throw new Error(`frontend config not found at ${TARGET}`);
  let src = fs.readFileSync(TARGET, "utf8");
  const changes: string[] = [];

  for (const { block, cfg, keys } of BLOCKS) {
    const cfgPath = path.join(__dirname, "..", "fork-ui", cfg);
    if (!fs.existsSync(cfgPath)) {
      console.log(`skip ${block} (no ${cfg})`);
      continue;
    }
    const json = JSON.parse(fs.readFileSync(cfgPath, "utf8"));
    const bounds = blockBounds(src, block);
    if (!bounds) {
      console.log(`skip ${block} (not found in contracts.ts)`);
      continue;
    }
    let [s, e] = bounds;
    let body = src.slice(s, e);

    for (const key of keys) {
      const value: string | undefined = json[key];
      if (!value) continue;
      // Only rewrite a key that already exists in the block; adding new ones would need a
      // type change, which is a human decision.
      const re = new RegExp(`(\\n\\s*${key}: ")0x[0-9a-fA-F]{40}(")`);
      const m = body.match(re);
      if (!m) continue;
      if (m[0].includes(value)) continue;
      body = body.replace(re, `$1${value}$2`);
      changes.push(`${block}.${key} -> ${value}`);
    }
    src = src.slice(0, s) + body + src.slice(e);
  }

  if (changes.length === 0) {
    console.log("frontend addresses already in sync");
    return;
  }
  fs.writeFileSync(TARGET, src);
  console.log(`updated ${TARGET}`);
  for (const c of changes) console.log("  " + c);
}

main();
