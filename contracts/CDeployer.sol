// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "./Collateral.sol";
import "./interfaces/ICDeployer.sol";

/*
 * This contract is used by the Factory to deploy Collateral(s)
 * The bytecode would be too long to fit in the Factory
 */
 
contract CDeployer is ICDeployer {
	constructor () {}
	
	function deployCollateral(address stratusALPT) external returns (address collateral) {
		bytes memory bytecode = type(Collateral).creationCode;
		bytes32 salt = keccak256(abi.encodePacked(msg.sender, stratusALPT));
		assembly {
			collateral := create2(0, add(bytecode, 32), mload(bytecode), salt)
		}
		require(collateral != address(0), "CREATE2_FAILED");
	}
}
