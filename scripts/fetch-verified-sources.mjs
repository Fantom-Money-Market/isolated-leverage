// Downloads verified source code for every external contract we integrate with
// (docs/EXTERNAL-ADDRESSES.md) from Sonicscan via the Etherscan V2 multichain API,
// unpacking each contract's standard-JSON into a real .sol file tree.
//
//   node scripts/fetch-verified-sources.mjs
//
// Reads SONICSCAN_API_KEY (or ETHERSCAN_API_KEY) from the environment, falling back to
// .env in the repo root. A free Etherscan account key works for all chains
// (chainid=146 = Sonic): https://etherscan.io/apis. Output goes to
// external-sources/<name>/ with a metadata.json (compiler, ABI, proxy info) per contract.
// Sourcify and the Sonic Labs explorer were checked first — neither serves these
// contracts' sources without a key, so the Etherscan API is the scripted route.

import * as fs from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");

/** Read a key from .env without needing it exported. Accepts `NAME=value`, `NAME: value`,
 *  optional `export ` prefix, and optional quotes — the repo's .env has used both `=` and
 *  `:` separators, and guessing wrong silently yields an "Invalid API Key" run. */
function fromDotEnv(names) {
  let text;
  try {
    text = fs.readFileSync(path.join(ROOT, ".env"), "utf8");
  } catch {
    return undefined;
  }
  for (const line of text.split(/\r?\n/)) {
    const m = line.match(/^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*[:=]\s*(.*)$/);
    if (!m) continue;
    if (!names.includes(m[1])) continue;
    const value = m[2].trim().replace(/^['"]|['"]$/g, "").trim();
    if (value) return value;
  }
  return undefined;
}

const KEY_NAMES = ["SONICSCAN_API_KEY", "ETHERSCAN_API_KEY"];
const API_KEY =
  process.env.SONICSCAN_API_KEY || process.env.ETHERSCAN_API_KEY || fromDotEnv(KEY_NAMES);
const CHAIN_ID = 146;
const OUT_DIR = path.join(ROOT, "external-sources");
const DELAY_MS = 350; // free tier: 5 req/s

const CONTRACTS = [
  // Shadow
  ["shadow-pool-usdce-ws", "0x324963c267C354c7660Ce8CA3F5f167E05649970"],
  ["shadow-gauge-v3", "0xe879d0E44e6873cf4ab71686055a4f6817685f02"],
  ["shadow-voter", "0x9F59398D0a397b2EEB8a6123a6c7295cB0b0062D"],
  // Beets / Balancer v3
  ["beets-v3-vault", "0xbA1333333333a1BA1108E8412f11850A5C319bA9"],
  ["beets-sts-ws-bpt", "0x75b000584a7d86fb3ef5e15ba26f4c52b41be0e9"],
  ["beets-gauge", "0xaE647ea922D392cC825c51967382940A30893f6D"],
  // Metropolis / DLMM
  ["metropolis-lb-factory", "0x39D966c1BaFe7D3F1F53dA4845805E15f7D6EE43"],
  ["metropolis-lbpair-ws-ussd-10", "0x361F55337074ae43957204CB30fFBAbbCe4Fb837"],
  ["metropolis-hook-clone", "0x0a377447D9D0d900B56C4BE5AbD332B873f6341e"],
  ["metropolis-hook-impl", "0xd7182dc736Cd322CA03312127d5291a5aF2fa610"],
  ["metropolis-masterchef-proxy", "0x1a5DEd6adCFC64acEDe86151b1f142088C6E03Da"],
  ["metropolis-masterchef-impl", "0x5B792016e9338353ae2b673c2eebdf26916cc906"],
  ["metro-ws-price-pair", "0xf2088eB2d7Bdc2d25C02a5B731f30CdA52862010"],
  // Tokens
  ["token-ws", "0x039e2fB66102314Ce7b64Ce5Ce3E5183bc94aD38"],
  ["token-usdce", "0x29219dd400f2Bf60E5a23d13Be72B486D4038894"],
  ["token-shadow", "0x3333b97138D4b086720b5aE8A7844b1345a33333"],
  ["token-sts", "0xE5DA20F15420aD15DE0fa650600aFc998bbE3955"],
  ["token-beets", "0x2D0E0814E62D80056181F5cd932274405966e4f0"],
  ["token-ussd", "0x000000000eCcFf26B795F73fb0A70d48da657fEf"],
  ["token-metro", "0x71E99522EaD5E21CF57F1f542Dc4ad2E841F7321"],
];

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** Etherscan returns SourceCode as "" | flat source | {..} | {{..}} (their double-brace quirk). */
function parseSources(raw, contractName) {
  if (!raw) return null;
  let text = raw.trim();
  if (text.startsWith("{{") && text.endsWith("}}")) text = text.slice(1, -1);
  if (text.startsWith("{")) {
    const json = JSON.parse(text);
    const sources = json.sources ?? json; // standard-JSON input vs bare sources map
    const out = {};
    for (const [p, v] of Object.entries(sources)) {
      if (v && typeof v.content === "string") out[p] = v.content;
    }
    if (Object.keys(out).length > 0) return out;
  }
  return { [`${contractName || "Contract"}.sol`]: text };
}

function safeJoin(base, rel) {
  const cleaned = rel.replace(/^[/\\]+/, "").replace(/\\/g, "/");
  const full = path.join(base, cleaned);
  if (!path.resolve(full).startsWith(path.resolve(base))) {
    throw new Error(`path escape attempt in source path: ${rel}`);
  }
  return full;
}

async function fetchContract(name, address) {
  // Already downloaded — skip so re-runs (e.g. the proxy-follow pass) don't burn quota.
  if (fs.existsSync(path.join(OUT_DIR, name, "metadata.json"))) {
    const meta = JSON.parse(fs.readFileSync(path.join(OUT_DIR, name, "metadata.json"), "utf8"));
    return { name, address, verified: true, cached: true, contractName: meta.contractName, files: 0, proxy: meta.implementation };
  }
  const url =
    `https://api.etherscan.io/v2/api?chainid=${CHAIN_ID}&module=contract` +
    `&action=getsourcecode&address=${address}&apikey=${API_KEY}`;
  const res = await fetch(url);
  const body = await res.json();
  if (body.status !== "1" || !Array.isArray(body.result)) {
    throw new Error(body.result || body.message || "unexpected API response");
  }
  const info = body.result[0];
  if (!info.SourceCode) {
    return { name, address, verified: false };
  }

  const dir = path.join(OUT_DIR, name);
  fs.mkdirSync(dir, { recursive: true });

  const sources = parseSources(info.SourceCode, info.ContractName);
  for (const [rel, content] of Object.entries(sources)) {
    const file = safeJoin(dir, rel);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, content);
  }

  fs.writeFileSync(
    path.join(dir, "metadata.json"),
    JSON.stringify(
      {
        address,
        contractName: info.ContractName,
        compiler: info.CompilerVersion,
        optimization: info.OptimizationUsed === "1",
        runs: info.Runs,
        evmVersion: info.EVMVersion,
        proxy: info.Proxy === "1",
        implementation: info.Implementation || null,
        abi: info.ABI && info.ABI !== "Contract source code not verified" ? JSON.parse(info.ABI) : null,
      },
      null,
      2,
    ),
  );

  return {
    name,
    address,
    verified: true,
    contractName: info.ContractName,
    files: Object.keys(sources).length,
    proxy: info.Proxy === "1" ? info.Implementation : null,
  };
}

async function main() {
  if (!API_KEY) {
    console.error(
      "No API key found in the environment or .env (looked for: " +
        KEY_NAMES.join(", ") +
        ").\nCreate a free key at https://etherscan.io/apis — it works for Sonic via the V2\n" +
        "multichain API — then add it to .env as  SONICSCAN_API_KEY=<key>",
    );
    process.exit(1);
  }

  fs.mkdirSync(OUT_DIR, { recursive: true });
  const summary = [];

  const run = async (queue) => {
    for (const [name, address] of queue) {
      try {
        const r = await fetchContract(name, address);
        summary.push(r);
        const tag = r.cached ? "cached   " : r.verified ? "ok       " : "UNVERIFIED";
        console.log(
          r.verified
            ? `${tag} ${name.padEnd(34)} ${r.contractName}` +
                (r.cached ? "" : ` (${r.files} files)`) +
                (r.proxy ? ` -> proxy for ${r.proxy}` : "")
            : `${tag} ${name.padEnd(34)} ${address}`,
        );
      } catch (e) {
        summary.push({ name, address, error: String(e.message || e) });
        console.log(`ERROR      ${name.padEnd(34)} ${e.message || e}`);
      }
      if (!summary[summary.length - 1]?.cached) await sleep(DELAY_MS);
    }
  };

  await run(CONTRACTS);

  // Second pass: a proxy's own source is just the forwarding shell — the logic we actually
  // need to read (e.g. GaugeV3.periodEarned) lives in its implementation. Follow any proxy
  // whose implementation isn't already in the list above.
  const known = new Set(CONTRACTS.map(([, a]) => a.toLowerCase()));
  const followed = [];
  for (const r of summary) {
    if (!r.proxy) continue;
    const impl = r.proxy.toLowerCase();
    if (known.has(impl)) continue;
    known.add(impl);
    followed.push([`${r.name}-impl`, r.proxy]);
  }
  if (followed.length > 0) {
    console.log(`\nfollowing ${followed.length} proxy implementation(s):`);
    await run(followed);
  }

  fs.writeFileSync(path.join(OUT_DIR, "_fetch-summary.json"), JSON.stringify(summary, null, 2));
  const ok = summary.filter((s) => s.verified).length;
  const unverified = summary.filter((s) => !s.verified && !s.error);
  console.log(`\n${ok}/${summary.length} verified sources in external-sources/`);
  if (unverified.length > 0) {
    console.log(
      `unverified (expected for minimal-proxy clones — read their implementation instead): ` +
        unverified.map((s) => s.name).join(", "),
    );
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
