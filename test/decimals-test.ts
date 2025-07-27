import { expect } from "chai";
import { ethers } from "hardhat";
import { TarotERC20, Borrowable, Collateral } from "../typechain-types";

describe("Decimals Function Test", function () {
  let tarotERC20: TarotERC20;
  let borrowable: Borrowable;
  let collateral: Collateral;

  beforeEach(async function () {
    // Deploy TarotERC20
    const TarotERC20Factory = await ethers.getContractFactory("TarotERC20");
    tarotERC20 = await TarotERC20Factory.deploy();

    // Deploy Borrowable
    const BorrowableFactory = await ethers.getContractFactory("Borrowable");
    borrowable = await BorrowableFactory.deploy();

    // Deploy Collateral
    const CollateralFactory = await ethers.getContractFactory("Collateral");
    collateral = await CollateralFactory.deploy();
  });

  it("should return correct decimals value for TarotERC20", async function () {
    const decimals = await tarotERC20.decimals();
    expect(decimals).to.equal(18);
  });

  it("should return correct decimals value for Borrowable", async function () {
    const decimals = await borrowable.decimals();
    expect(decimals).to.equal(18);
  });

  it("should return correct decimals value for Collateral", async function () {
    const decimals = await collateral.decimals();
    expect(decimals).to.equal(18);
  });
});