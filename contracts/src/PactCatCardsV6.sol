// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice ERC-1155 receiver hook (EIP-1155). Smart accounts such as the ZeroDev Kernel v3.3
/// implementation answer it with its selector.
interface IERC1155ReceiverV6 {
    function onERC1155Received(address operator, address from, uint256 id, uint256 value, bytes calldata data)
        external returns (bytes4);

    function onERC1155BatchReceived(address operator, address from, uint256[] calldata ids,
        uint256[] calldata values, bytes calldata data) external returns (bytes4);
}

/// @title PactCatCardsV6
/// @notice Soulbound ERC-1155 cat cards. The database is authoritative for which cards a
/// player owns; this contract is the on-chain mirror the server mints through its outbox.
///
/// - Only the immutable minter mints (`mint`, `mintBatch`). There is no burn, no owner, no
///   pause and no upgrade path.
/// - Cards are soulbound: `safeTransferFrom`, `safeBatchTransferFrom` and `setApprovalForAll`
///   always revert, and `isApprovedForAll` is always false, so no operator can ever exist.
/// - Minting to a contract follows EIP-1155 safe-transfer rules (the receiver must answer the
///   hook with its selector); minting to an EOA needs no hook.
/// - `uri(id)` is `baseURI ‖ decimal(id)`, `contractURI()` the collection metadata (ERC-7572).
///   Both point at the Pact server, and the CC BY-SA photo attribution lives in that metadata.
///   The strings are fixed at construction.
///
/// UNAUDITED FUJI-ONLY PROTOTYPE. The constructor refuses every chain except Avalanche Fuji
/// (43113) and the local test chain (31337). Never represent this as production-safe.
contract PactCatCardsV6 {
    string public constant name = "Pact Cat Cards";
    string public constant symbol = "CATCARD";

    bytes4 internal constant ERC165_INTERFACE = 0x01ffc9a7;
    bytes4 internal constant ERC1155_INTERFACE = 0xd9b67a26;
    bytes4 internal constant ERC1155_METADATA_URI_INTERFACE = 0x0e89341c;
    uint256 internal constant MAX_BATCH = 64;

    address public immutable minter;

    string private baseURI;
    string private collectionURI;

    mapping(uint256 id => mapping(address account => uint256 balance)) private balances;
    mapping(uint256 id => uint256 supply) public totalSupply;

    event TransferSingle(address indexed operator, address indexed from, address indexed to, uint256 id,
        uint256 value);
    event TransferBatch(address indexed operator, address indexed from, address indexed to, uint256[] ids,
        uint256[] values);
    /// @dev Declared for the ERC-1155 ABI; never emitted (no approval can exist).
    event ApprovalForAll(address indexed account, address indexed operator, bool approved);
    /// @dev Declared for the ERC-1155 ABI; never emitted (the URIs are fixed).
    event URI(string value, uint256 indexed id);

    error InvalidConfiguration();
    error NotMinter();
    error Soulbound();
    error InvalidRecipient();
    error InvalidAmount();
    error LengthMismatch();
    error ReceiverRejected();

    modifier onlyMinter() {
        if (msg.sender != minter) revert NotMinter();
        _;
    }

    constructor(address minter_, string memory baseURI_, string memory contractURI_) {
        if (block.chainid != 43113 && block.chainid != 31337) revert InvalidConfiguration();
        if (minter_ == address(0) || minter_ == address(this) || bytes(baseURI_).length == 0
            || bytes(contractURI_).length == 0) {
            revert InvalidConfiguration();
        }
        minter = minter_;
        baseURI = baseURI_;
        collectionURI = contractURI_;
    }

    // ---------------------------------------------------------------------
    // Minting
    // ---------------------------------------------------------------------

    function mint(address to, uint256 id, uint256 amount, bytes calldata data) external onlyMinter {
        if (to == address(0) || to == address(this)) revert InvalidRecipient();
        if (amount == 0) revert InvalidAmount();
        balances[id][to] += amount;
        totalSupply[id] += amount;
        emit TransferSingle(msg.sender, address(0), to, id, amount);
        if (to.code.length != 0) {
            _checkReceiver(abi.encodeCall(IERC1155ReceiverV6.onERC1155Received,
                (msg.sender, address(0), id, amount, data)), to, IERC1155ReceiverV6.onERC1155Received.selector);
        }
    }

    function mintBatch(address to, uint256[] calldata ids, uint256[] calldata amounts, bytes calldata data)
        external onlyMinter
    {
        if (to == address(0) || to == address(this)) revert InvalidRecipient();
        if (ids.length != amounts.length || ids.length == 0 || ids.length > MAX_BATCH) revert LengthMismatch();
        for (uint256 i; i < ids.length; ++i) {
            if (amounts[i] == 0) revert InvalidAmount();
            balances[ids[i]][to] += amounts[i];
            totalSupply[ids[i]] += amounts[i];
        }
        emit TransferBatch(msg.sender, address(0), to, ids, amounts);
        if (to.code.length != 0) {
            _checkReceiver(abi.encodeCall(IERC1155ReceiverV6.onERC1155BatchReceived,
                (msg.sender, address(0), ids, amounts, data)), to, IERC1155ReceiverV6.onERC1155BatchReceived.selector);
        }
    }

    // ---------------------------------------------------------------------
    // ERC-1155 views
    // ---------------------------------------------------------------------

    function balanceOf(address account, uint256 id) external view returns (uint256) {
        return balances[id][account];
    }

    function balanceOfBatch(address[] calldata accounts, uint256[] calldata ids)
        external view returns (uint256[] memory result)
    {
        if (accounts.length != ids.length) revert LengthMismatch();
        result = new uint256[](accounts.length);
        for (uint256 i; i < accounts.length; ++i) result[i] = balances[ids[i]][accounts[i]];
    }

    function isApprovedForAll(address, address) external pure returns (bool) {
        return false;
    }

    function uri(uint256 id) external view returns (string memory) {
        return string.concat(baseURI, _toDecimal(id));
    }

    function contractURI() external view returns (string memory) {
        return collectionURI;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == ERC165_INTERFACE || interfaceId == ERC1155_INTERFACE
            || interfaceId == ERC1155_METADATA_URI_INTERFACE;
    }

    // ---------------------------------------------------------------------
    // Soulbound: every transfer and approval path reverts
    // ---------------------------------------------------------------------

    function setApprovalForAll(address, bool) external pure {
        revert Soulbound();
    }

    function safeTransferFrom(address, address, uint256, uint256, bytes calldata) external pure {
        revert Soulbound();
    }

    function safeBatchTransferFrom(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external pure
    {
        revert Soulbound();
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    /// @dev EIP-1155 acceptance check: the receiver must return exactly the hook selector.
    /// Any revert (including a missing hook) or another answer reverts the mint. At most 32
    /// bytes of return data are ever copied, so a receiver cannot grief the minter with a
    /// return-data bomb.
    function _checkReceiver(bytes memory callData, address to, bytes4 expected) private {
        bool success;
        uint256 size;
        bytes32 answer;
        assembly ("memory-safe") {
            success := call(gas(), to, 0, add(callData, 32), mload(callData), 0, 0)
            size := returndatasize()
            if gt(size, 31) {
                returndatacopy(0, 0, 32)
                answer := mload(0)
            }
        }
        if (!success || size != 32 || bytes4(answer) != expected) revert ReceiverRejected();
    }

    function _toDecimal(uint256 value) private pure returns (string memory) {
        if (value == 0) return "0";
        uint256 digits;
        for (uint256 probe = value; probe != 0; probe /= 10) ++digits;
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            buffer[--digits] = bytes1(uint8(48 + value % 10));
            value /= 10;
        }
        return string(buffer);
    }
}
