// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @dev Test token that attempts a reentrant Registry.claim while the Vault is
/// paying a claim. Reentry is opt-in so join and settlement flows stay usable,
/// and the Vault is expected to reject the callback through its Reentrancy guard.
contract ReentrantERC20 {
    uint8 public constant decimals = 6;

    mapping(address account => uint256 balance) public balanceOf;
    mapping(address owner => mapping(address spender => uint256 amount)) public allowance;

    address public reentryTarget;
    uint256 public reentryPactId;
    bool public reentryEnabled;
    bool public swallowReentryFailure;
    bool public reentryAttempted;
    bool public reentrySucceeded;
    bytes4 public lastReentryError;

    bool private insideHook;

    error InsufficientBalance();
    error InsufficientAllowance();
    error ReentrySucceeded();

    function configureReentry(address target, uint256 pactId, bool enabled, bool swallowFailure) external {
        reentryTarget = target;
        reentryPactId = pactId;
        reentryEnabled = enabled;
        swallowReentryFailure = swallowFailure;
    }

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        _attemptReentry();
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 approved = allowance[from][msg.sender];
        if (approved < amount) revert InsufficientAllowance();
        allowance[from][msg.sender] = approved - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) private {
        if (balanceOf[from] < amount) revert InsufficientBalance();
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }

    function _attemptReentry() private {
        if (!reentryEnabled || insideHook) return;
        insideHook = true;
        reentryAttempted = true;
        (bool success, bytes memory data) = reentryTarget.call(
            abi.encodeWithSignature("claim(uint256)", reentryPactId)
        );
        if (success) {
            reentrySucceeded = true;
            if (!swallowReentryFailure) revert ReentrySucceeded();
        } else {
            lastReentryError = data.length >= 4 ? bytes4(data) : bytes4(0);
            if (!swallowReentryFailure) {
                assembly ("memory-safe") {
                    revert(add(data, 32), mload(data))
                }
            }
        }
        insideHook = false;
    }
}
