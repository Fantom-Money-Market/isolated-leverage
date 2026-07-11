// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import "../../contracts/Stratus-ALM/interfaces/ILBPair.sol";
import "../../contracts/Stratus-ALM/libraries/LiquidityBookMath.sol";

contract DLMMConfigDecodeTest is Test {
    address constant PAIR = 0x361F55337074ae43957204CB30fFBAbbCe4Fb837;

    function test_decodeMintConfigsFromTrace() public {
        // Captured from forge -vvvv trace after leverage/unwind second deployIdle
        bytes32 yBin = bytes32(uint256(0x00000000000000000000000000000000000000000002c68af0bb1400007ff192));
        bytes32 xBin = bytes32(uint256(0x0000000000000000000000000006f05b59d3b200000000000000000007ff198));

        uint24 idY = uint24(uint256(yBin));
        uint64 distY_y = uint64(uint256(yBin >> 24));
        uint64 distX_y = uint64(uint256(yBin >> 88));

        uint24 idX = uint24(uint256(xBin));
        uint64 distY_x = uint64(uint256(xBin >> 24));
        uint64 distX_x = uint64(uint256(xBin >> 88));

        emit log_named_uint("yBin id", idY);
        emit log_named_uint("yBin distY", distY_y);
        emit log_named_uint("yBin distX", distX_y);
        emit log_named_uint("xBin id", idX);
        emit log_named_uint("xBin distY", distY_x);
        emit log_named_uint("xBin distX", distX_x);

        // What our encode produces for distX=5e17, distY=0
        bytes32 enc = LiquidityBookMath.encodeLiquidityConfig(5e17, 0, uint24(8384920));
        emit log_named_bytes32("encode(5e17,0)", enc);
        emit log_named_uint("enc distY", uint64(uint256(enc >> 24)));
        emit log_named_uint("enc distX", uint64(uint256(enc >> 88)));
    }

    function test_pairTokenOrder() public {
        string memory rpc = vm.envOr("SONIC_RPC_URL", string("https://rpc.soniclabs.com"));
        vm.createSelectFork(rpc);
        emit log_named_address("tokenX", ILBPair(PAIR).getTokenX());
        emit log_named_address("tokenY", ILBPair(PAIR).getTokenY());
        emit log_named_uint("activeId", ILBPair(PAIR).getActiveId());
    }
}
