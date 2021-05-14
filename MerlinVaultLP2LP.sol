// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/IBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/math/Math.sol";

// import "./library/Math.sol";
import "./library/VaultController.sol";
import "./library/PoolConstant.sol";

import "./interface/IPancakePair.sol";
import "./interface/IStrategy.sol";
import "./interface/IMasterChef.sol";
import "./interface/IMerlinMinter.sol";
import "./interface/IZapBSC.sol";

contract MerlinVaultLP2LP is VaultController, IStrategy {
    using SafeBEP20 for IBEP20;
    using SafeMath for uint256;

    /* ========== CONSTANTS ============= */
    IBEP20 private CAKE;
    IBEP20 private WBNB;
    IMasterChef private CAKE_MASTER_CHEF;
    IZapBSC private zapBSC;

    PoolConstant.PoolTypes public constant override poolType = PoolConstant.PoolTypes.FlipToFlip;
    uint private constant DUST = 1000;

    /* ========== STATE VARIABLES ========== */
    uint public pid;

    address private _token0;
    address private _token1;

    uint public totalShares;
    mapping (address => uint) private _shares;
    mapping (address => uint) private _principal;
    mapping (address => uint) private _depositedAt;

    uint public cakeHarvested;

    /* ========== MODIFIER ========== */

    modifier updateCakeHarvested {
        uint before = CAKE.balanceOf(address(this));
        _;
        uint _after = CAKE.balanceOf(address(this));
        cakeHarvested = cakeHarvested.add(_after).sub(before);
    }

    /* ========== INITIALIZER ========== */

    function initialize(
        uint _pid, 
        address _token, 
        address _merlin,
        address _cake,
        address _wbnb,
        address _masterchef,
        address _zap
    ) external initializer {
        __VaultController_init(IBEP20(_token), _merlin);

        pid = _pid;
        CAKE = IBEP20(_cake);
        WBNB = IBEP20(_wbnb);
        CAKE_MASTER_CHEF = IMasterChef(_masterchef);
        zapBSC = IZapBSC(_zap);

        _stakingToken.safeApprove(address(CAKE_MASTER_CHEF), uint(- 1));
        CAKE.safeApprove(address(zapBSC), uint(- 1));
    }

    /* ========== VIEW FUNCTIONS ========== */

    function totalSupply() external view override returns (uint) {
        return totalShares;
    }

    function balance() public view override returns (uint amount) {
        (amount,) = CAKE_MASTER_CHEF.userInfo(pid, address(this));
    }

    function balanceOf(address account) public view override returns(uint) {
        if (totalShares == 0) return 0;
        return balance().mul(sharesOf(account)).div(totalShares);
    }

    function withdrawableBalanceOf(address account) public view override returns (uint) {
        return balanceOf(account);
    }

    function sharesOf(address account) public view override returns (uint) {
        return _shares[account];
    }

    function principalOf(address account) public view override returns (uint) {
        return _principal[account];
    }

    function earned(address account) public view override returns (uint) {
        if (balanceOf(account) >= principalOf(account) + DUST) {
            return balanceOf(account).sub(principalOf(account));
        } else {
            return 0;
        }
    }

    function depositedAt(address account) external view override returns (uint) {
        return _depositedAt[account];
    }

    function rewardsToken() external override  view returns (address) {
        return address(_stakingToken);
    }

    function priceShare() external override view returns(uint) {
        if (totalShares == 0) return 1e18;
        return balance().mul(1e18).div(totalShares);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function deposit(uint _amount) public override {
        _depositTo(_amount, msg.sender);
    }

    function depositAll() external override {
        deposit(_stakingToken.balanceOf(msg.sender));
    }

    function withdrawAll() external override {
        uint amount = balanceOf(msg.sender);
        uint principal = principalOf(msg.sender);
        uint depositTimestamp = _depositedAt[msg.sender];

        totalShares = totalShares.sub(_shares[msg.sender]);
        delete _shares[msg.sender];
        delete _principal[msg.sender];
        delete _depositedAt[msg.sender];

        amount = _withdrawTokenWithCorrection(amount);
        uint profit = amount > principal ? amount.sub(principal) : 0;

        uint withdrawalFee = canMint() ? _minter.withdrawalFee(principal, depositTimestamp) : 0;
        uint performanceFee = canMint() ? _minter.performanceFee(profit) : 0;
        if (withdrawalFee.add(performanceFee) > DUST) {
            _minter.mintFor(address(_stakingToken), withdrawalFee, performanceFee, msg.sender, depositTimestamp);

            if (performanceFee > 0) {
                emit ProfitPaid(msg.sender, profit, performanceFee);
            }
            amount = amount.sub(withdrawalFee).sub(performanceFee);
        }

        _stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount, withdrawalFee);
    }

    function harvest() external override onlyKeeper {
        _harvest();

        uint before = _stakingToken.balanceOf(address(this));
        if ( cakeHarvested <= DUST ) {
            return;
        }
        zapBSC.zapInToken(address(CAKE), cakeHarvested, address(_stakingToken));
        uint harvested = _stakingToken.balanceOf(address(this)).sub(before);

        CAKE_MASTER_CHEF.deposit(pid, harvested);
        emit Harvested(harvested);

        cakeHarvested = 0;
    }

    function _harvest() private updateCakeHarvested {
        CAKE_MASTER_CHEF.withdraw(pid, 0);
    }

    function withdraw(uint shares) external override onlyWhitelisted {
        uint amount = balance().mul(shares).div(totalShares);
        totalShares = totalShares.sub(shares);
        _shares[msg.sender] = _shares[msg.sender].sub(shares);

        amount = _withdrawTokenWithCorrection(amount);
        _stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount, 0);
    }

    // @dev underlying only + withdrawal fee + no perf fee
    function withdrawUnderlying(uint _amount) external {
        uint amount = Math.min(_amount, _principal[msg.sender]);
        uint shares = Math.min(amount.mul(totalShares).div(balance()), _shares[msg.sender]);
        totalShares = totalShares.sub(shares);
        _shares[msg.sender] = _shares[msg.sender].sub(shares);
        _principal[msg.sender] = _principal[msg.sender].sub(amount);

        amount = _withdrawTokenWithCorrection(amount);
        uint depositTimestamp = _depositedAt[msg.sender];
        uint withdrawalFee = canMint() ? _minter.withdrawalFee(amount, depositTimestamp) : 0;
        if (withdrawalFee > DUST) {
            _minter.mintFor(address(_stakingToken), withdrawalFee, 0, msg.sender, depositTimestamp);
            amount = amount.sub(withdrawalFee);
        }

        _stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount, withdrawalFee);
    }

    // @dev profits only (underlying + merlin) + no withdraw fee + perf fee
    function getReward() external override {
        uint amount = earned(msg.sender);
        uint shares = Math.min(amount.mul(totalShares).div(balance()), _shares[msg.sender]);
        totalShares = totalShares.sub(shares);
        _shares[msg.sender] = _shares[msg.sender].sub(shares);
        _cleanupIfDustShares();

        amount = _withdrawTokenWithCorrection(amount);
        uint depositTimestamp = _depositedAt[msg.sender];
        uint performanceFee = canMint() ? _minter.performanceFee(amount) : 0;
        if (performanceFee > DUST) {
            _minter.mintFor(address(_stakingToken), 0, performanceFee, msg.sender, depositTimestamp);
            amount = amount.sub(performanceFee);
        }

        _stakingToken.safeTransfer(msg.sender, amount);
        emit ProfitPaid(msg.sender, amount, performanceFee);
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    function _depositTo(uint _amount, address _to) private notPaused updateCakeHarvested {
        uint _pool = balance();
        uint _before = _stakingToken.balanceOf(address(this));
        _stakingToken.safeTransferFrom(msg.sender, address(this), _amount);
        uint _after = _stakingToken.balanceOf(address(this));
        _amount = _after.sub(_before); // Additional check for deflationary tokens
        uint shares = 0;
        if (totalShares == 0) {
            shares = _amount;
        } else {
            shares = (_amount.mul(totalShares)).div(_pool);
        }

        totalShares = totalShares.add(shares);
        _shares[_to] = _shares[_to].add(shares);
        _principal[_to] = _principal[_to].add(_amount);
        _depositedAt[_to] = block.timestamp;

        CAKE_MASTER_CHEF.deposit(pid, _amount);
        emit Deposited(_to, _amount);
    }

    function _withdrawTokenWithCorrection(uint amount) private updateCakeHarvested returns (uint) {
        uint before = _stakingToken.balanceOf(address(this));
        CAKE_MASTER_CHEF.withdraw(pid, amount);
        return _stakingToken.balanceOf(address(this)).sub(before);
    }

    function _cleanupIfDustShares() private {
        uint shares = _shares[msg.sender];
        if (shares > 0 && shares < DUST) {
            totalShares = totalShares.sub(shares);
            delete _shares[msg.sender];
        }
    }

    /* ========== SALVAGE PURPOSE ONLY ========== */

    // @dev stakingToken must not remain balance in this contract. So dev should salvage staking token transferred by mistake.
    function recoverToken(address token, uint amount) external override onlyOwner {
        if (token == address(CAKE)) {
            uint cakeBalance = CAKE.balanceOf(address(this));
            require(amount <= cakeBalance.sub(cakeHarvested), "VaultFlipToFlip: cannot recover lp's harvested cake");
        }

        IBEP20(token).safeTransfer(owner(), amount);
        emit Recovered(token, amount);
    }

    /* ========== MIGRATE PANCAKE V1 to V2 ========== */

    function migrate(address account, uint amount) public {
        if (amount == 0) return;
        _depositTo(amount, account);
    }

    function migrateToken(uint amount) public onlyOwner {
        _stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        CAKE_MASTER_CHEF.deposit(pid, amount);
    }

    function setPidToken(uint _pid, address token) external onlyOwner {
        require(totalShares == 0);
        pid = _pid;
        _stakingToken = IBEP20(token);

        _stakingToken.safeApprove(address(CAKE_MASTER_CHEF), 0);
        _stakingToken.safeApprove(address(CAKE_MASTER_CHEF), uint(- 1));

        _stakingToken.safeApprove(address(_minter), 0);
        _stakingToken.safeApprove(address(_minter), uint(- 1));
    }
}