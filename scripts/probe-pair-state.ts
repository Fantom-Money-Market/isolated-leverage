import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";
const ABI = [
  "function getReserves() view returns (uint128,uint128)",
  "function getActiveId() view returns (uint24)",
  "function getBin(uint24) view returns (uint128,uint128)",
];
async function main() {
  const cfg = JSON.parse(fs.readFileSync(path.join(__dirname,"..","fork-ui","dlmm-config.json"),"utf8"));
  const p = new ethers.Contract(cfg.pair, ABI, ethers.provider);
  const [rx, ry] = await p.getReserves();
  const id = await p.getActiveId();
  console.log("activeId:", id.toString());
  console.log("reserveX (wS)  :", ethers.formatEther(rx));
  console.log("reserveY (USSD):", ethers.formatEther(ry));
}
main().catch(e=>{console.error(e);process.exit(1);});
