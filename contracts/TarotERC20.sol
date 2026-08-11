// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract TarotERC20 is IERC20, IERC20Metadata {
    // --- Custom Errors ---
    error TransferTooHigh();
    error TransferNotAllowed();
    error Expired();
    error InvalidSignature();

    // --- State Variables ---
    string public override name;
    string public override symbol;
    uint8 public override decimals = 18;
    uint256 public override totalSupply;
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    mapping(address => uint256) public nonces;

    // Cached at _setName time; DOMAIN_SEPARATOR() below recomputes on the fly if the
    // live chainid ever diverges from what's cached (see DOMAIN_SEPARATOR doc comment).
    bytes32 private _cachedDomainSeparator;
    uint256 private _cachedChainId;
    bytes32 private _hashedName;

    // --- Events ---
    // Transfer and Approval events are inherited from IERC20

    // --- Constants ---
    // keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 public constant PERMIT_TYPEHASH =
        0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;

    constructor() {}

    function _setName(string memory _name, string memory _symbol) internal {
        name = _name;
        symbol = _symbol;
        _hashedName = keccak256(bytes(_name));
        _cachedChainId = block.chainid;
        _cachedDomainSeparator = _buildDomainSeparator();
    }

    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                _hashedName,
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

    /// @notice EIP-712 domain separator. Uses the cached value when chainid matches deploy,
    ///         otherwise recomputes so permits cannot be replayed across a chain fork.
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        if (block.chainid == _cachedChainId) {
            return _cachedDomainSeparator;
        }
        return _buildDomainSeparator();
    }

    function _mint(address to, uint256 value) internal {
        totalSupply += value;
        balanceOf[to] += value;
        emit Transfer(address(0), to, value);
    }

    function _burn(address from, uint256 value) internal {
        uint256 fromBalance = balanceOf[from];
        if (fromBalance < value) revert TransferTooHigh();
        balanceOf[from] = fromBalance - value;
        totalSupply -= value;
        emit Transfer(from, address(0), value);
    }

    function _approve(
        address owner,
        address spender,
        uint256 value
    ) private {
        allowance[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    function _transfer(
        address from,
        address to,
        uint256 value
    ) internal virtual {
        uint256 fromBalance = balanceOf[from];
        if (fromBalance < value) revert TransferTooHigh();
        balanceOf[from] = fromBalance - value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
    }

    function approve(address spender, uint256 value) external override returns (bool) {
        _approve(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external override returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 value
    ) external override returns (bool) {
        uint256 currentAllowance = allowance[from][msg.sender];
        if (currentAllowance != type(uint256).max) {
            if (currentAllowance < value) revert TransferNotAllowed();
            unchecked {
                allowance[from][msg.sender] = currentAllowance - value;
            }
        }
        _transfer(from, to, value);
        return true;
    }

    function _checkSignature(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s,
        bytes32 typehash
    ) internal {
        if (deadline < block.timestamp) revert Expired();
        // Read-then-consume the nonce so the signature cannot be replayed.
        uint256 currentNonce = nonces[owner];
        bytes32 digest =
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    DOMAIN_SEPARATOR(),
                    keccak256(
                        abi.encode(
                            typehash,
                            owner,
                            spender,
                            value,
                            currentNonce,
                            deadline
                        )
                    )
                )
            );
        address recoveredAddress = ecrecover(digest, v, r, s);
        if (recoveredAddress == address(0) || recoveredAddress != owner) {
            revert InvalidSignature();
        }
        nonces[owner] = currentNonce + 1;
    }

    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        // Single nonce-consuming path shared with borrowPermit (see _checkSignature).
        _checkSignature(owner, spender, value, deadline, v, r, s, PERMIT_TYPEHASH);
        _approve(owner, spender, value);
    }
}
