// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title PactGemV6
/// @notice "Pact Gems": the zero-value, earned-only stake token of the gem generation.
///
/// Gems are an in-game score, not money. They are minted only by the immutable Pact minter
/// (the server's mint outbox) and they can only move along three edges:
/// - mint:          minter      -> holder         (`mint`, `mintBatch`)
/// - stake:         holder      -> vault          (`transferFrom` called BY the vault, to itself)
/// - claim:         vault       -> holder         (`transfer` called BY the vault)
/// and leave circulation only through the holder's own burn:
/// - self-burn:     holder      -> nowhere        (`burn`; the solo "the cat keeps your gems" stake)
/// Every other transfer, including holder -> holder and a direct `transfer` into the vault,
/// reverts. `approve` works for exactly one spender, the vault, so the existing approve-batch
/// flow (approve(vault, 0), approve(vault, stake), create/join) is unchanged and no allowance to
/// anyone else can exist. The minter has no burn power at all (no `burnFrom`): a standing
/// allowance could otherwise let a hot server key burn gems long after the holder's consent.
///
/// There is deliberately no permit, no bridge hook, no owner, no pause and no upgrade path.
/// The vault address is a CREATE prediction passed in by the deployment plan; the minter can
/// never be the vault, so custody can never be minted into or burned out of.
///
/// Conservation: because nothing but the vault's own `transferFrom` can increase the vault's
/// balance, `balanceOf(vault) + SUM(paidOut) == SUM(deposited)` holds with strict equality
/// (no donations are possible).
///
/// UNAUDITED FUJI-ONLY PROTOTYPE. The constructor refuses every chain except Avalanche Fuji
/// (43113) and the local test chain (31337). Never represent this as production-safe.
contract PactGemV6 {
    string public constant name = "Pact Gems";
    string public constant symbol = "GEM";
    /// @dev The gem registry requires 6 decimals: its stake limits are 1..250 gems.
    uint8 public constant decimals = 6;

    /// @dev The only key that can create gems (the server's mint outbox signer).
    address public immutable minter;
    /// @dev The gem-generation vault (CREATE-predicted at deployment).
    address public immutable vault;

    uint256 public totalSupply;
    mapping(address account => uint256 balance) public balanceOf;
    mapping(address owner => mapping(address spender => uint256 amount)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error InvalidConfiguration();
    error NotMinter();
    error TransferRestricted();
    error ApprovalRestricted();
    error InvalidRecipient();
    error InvalidAmount();
    error InsufficientBalance();
    error InsufficientAllowance();
    error LengthMismatch();

    modifier onlyMinter() {
        if (msg.sender != minter) revert NotMinter();
        _;
    }

    constructor(address minter_, address vault_) {
        if (block.chainid != 43113 && block.chainid != 31337) revert InvalidConfiguration();
        if (minter_ == address(0) || vault_ == address(0) || minter_ == vault_
            || minter_ == address(this) || vault_ == address(this)) {
            revert InvalidConfiguration();
        }
        minter = minter_;
        vault = vault_;
    }

    // ---------------------------------------------------------------------
    // Minting and burning
    // ---------------------------------------------------------------------

    function mint(address to, uint256 amount) external onlyMinter {
        _mint(to, amount);
    }

    /// @notice Batched mint for the server's mint outbox (bonus gems, daily little things).
    function mintBatch(address[] calldata recipients, uint256[] calldata amounts) external onlyMinter {
        if (recipients.length != amounts.length || recipients.length == 0) revert LengthMismatch();
        for (uint256 i; i < recipients.length; ++i) _mint(recipients[i], amounts[i]);
    }

    /// @notice Destroys the caller's own gems. A solo Pact stakes this way: the holder burns at
    /// the start ("the cat keeps your gems") and the minter re-mints on success. The vault can
    /// never burn its custody.
    function burn(uint256 amount) external {
        if (msg.sender == vault) revert TransferRestricted();
        _burn(msg.sender, amount);
    }

    // ---------------------------------------------------------------------
    // Restricted ERC-20 surface
    // ---------------------------------------------------------------------

    /// @notice Only the vault can ever be approved (approving zero resets a stale allowance);
    /// the vault itself can never approve anyone.
    function approve(address spender, uint256 amount) external returns (bool) {
        if (spender != vault || msg.sender == vault) revert ApprovalRestricted();
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// @notice Only the vault transfers directly: a claim paying a holder.
    function transfer(address to, uint256 amount) external returns (bool) {
        if (msg.sender != vault) revert TransferRestricted();
        if (to == address(0) || to == vault || to == address(this)) revert InvalidRecipient();
        _move(msg.sender, to, amount);
        return true;
    }

    /// @notice Only the vault pulls, and only into itself: a stake deposit.
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (msg.sender != vault || to != vault || from == vault) revert TransferRestricted();
        _spendAllowance(from, msg.sender, amount);
        _move(from, to, amount);
        return true;
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    function _mint(address to, uint256 amount) private {
        if (to == address(0) || to == vault || to == address(this)) revert InvalidRecipient();
        if (amount == 0) revert InvalidAmount();
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function _burn(address holder, uint256 amount) private {
        if (amount == 0) revert InvalidAmount();
        uint256 balance = balanceOf[holder];
        if (balance < amount) revert InsufficientBalance();
        unchecked {
            balanceOf[holder] = balance - amount;
            totalSupply -= amount;
        }
        emit Transfer(holder, address(0), amount);
    }

    function _move(address from, address to, uint256 amount) private {
        uint256 balance = balanceOf[from];
        if (balance < amount) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = balance - amount;
        }
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }

    function _spendAllowance(address owner, address spender, uint256 amount) private {
        uint256 approved = allowance[owner][spender];
        if (approved < amount) revert InsufficientAllowance();
        unchecked {
            allowance[owner][spender] = approved - amount;
        }
    }
}
