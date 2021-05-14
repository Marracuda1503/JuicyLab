// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/IBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/math/Math.sol";
// import "@openzeppelin/contracts/utils/Pausable.sol";

import "./interface/IStakingRewards.sol";
import "./interface/IStrategy.sol";
import "./interface/IStrategyHelper.sol";
import "./interface/IPancakeRouter02.sol";
import "./interface/IZapBSC.sol";

import "./library/Pausable.sol";
import "./library/PoolConstant.sol";
import "./library/RewardsDistributionRecipient.sol";

import "./PriceCalculatorBSC.sol";

contract MerlinPool is IStrategy, RewardsDistributionRecipient, ReentrancyGuard, Pausable {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    /* ========== STATE VARIABLES ========== */

    IBEP20 public _rewardsToken;
    IBEP20 public  _stakingToken;
    address public merlinBNB;
    address public  WBNB;
    uint256 public periodFinish = 0;
    uint256 public rewardRate = 0;
    uint256 public rewardsDuration = 90 days;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    IZapBSC public zapBSC;
    address public BTCB;
    address public ETH;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;
    mapping(address => uint) private _depositedAt;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;

    mapping(address => bool) private _stakePermission;

    /* ========== HELPER ========= */
    PriceCalculatorBSC private  priceCalculator;
    IPancakeRouter02 private ROUTER;

    PoolConstant.PoolTypes public constant override poolType = PoolConstant.PoolTypes.MerlinPool;

    /* ========== CONSTRUCTOR ========== */
    constructor(
        address _merlin,
        address _router,
        address _priceCalc,
        address _merlinBNB,
        address _wbnb,
        address _zapBSC,
        address _btcb,
        address _eth
    ) public {
        _stakingToken = IBEP20(_merlin);
        ROUTER = IPancakeRouter02(_router);
        priceCalculator = PriceCalculatorBSC(_priceCalc);
        merlinBNB = _merlinBNB;
        WBNB = _wbnb;
        zapBSC = IZapBSC(_zapBSC);
        BTCB = _btcb;
        ETH = _eth;

        rewardsDistribution = msg.sender;

        _stakePermission[msg.sender] = true;

        _stakingToken.safeApprove(address(ROUTER), uint(~0));

        IBEP20(WBNB).safeApprove(address(ROUTER), uint(~0));
        IBEP20(_btcb).safeApprove(address(ROUTER), uint(~0));
        IBEP20(_eth).safeApprove(address(ROUTER), uint(~0));

    }

    /* ========== VIEWS ========== */

    function totalSupply() override external view  returns (uint256) {
        return _totalSupply;
    }

    function balance() override external view returns (uint) {
        return _totalSupply;
    }

    function balanceOf(address account) override external view returns (uint256) {
        return _balances[account];
    }

    function principalOf(address account) override external view returns (uint256) {
        return _balances[account];
    }

    function withdrawableBalanceOf(address account) override public view returns (uint) {
            return _balances[account];
    }

    function profitOf(address account) public view returns (uint _usd, uint _merlin, uint _bnb) {
        _usd = 0;
        _merlin = 0;
        (_bnb,) = priceCalculator.valueOfAsset(address(_rewardsToken), earned(account));
    }

    function tvl() public view returns (uint valueInBNB) {
        ( valueInBNB,) = priceCalculator.valueOfAsset(address(_stakingToken), _totalSupply);
    }

    function apy() public view returns(uint _usd, uint _merlin, uint _bnb) {
        uint tokenDecimals = 1e18;
        uint __totalSupply = _totalSupply;
        if (__totalSupply == 0) {
            __totalSupply = tokenDecimals;
        }

        uint rewardPerTokenPerSecond = rewardRate.mul(tokenDecimals).div(__totalSupply);
        ( uint merlinPrice,) = priceCalculator.valueOfAsset(address(_stakingToken), 1e18);

        _usd = 0;
        _merlin = 0;
        _bnb = rewardPerTokenPerSecond.mul(365 days).mul(1e18).div(merlinPrice);
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return Math.min(block.timestamp, periodFinish);
    }

    function rewardPerToken() public view returns (uint256) {
        if (_totalSupply == 0) {
            return rewardPerTokenStored;
        }
        return
        rewardPerTokenStored.add(
            lastTimeRewardApplicable().sub(lastUpdateTime).mul(rewardRate).mul(1e18).div(_totalSupply)
        );
    }

    function earned(address account) override public view returns (uint256) {
        return _balances[account].mul(rewardPerToken().sub(userRewardPerTokenPaid[account])).div(1e18).add(rewards[account]);
    }

    function getRewardForDuration() external view returns (uint256) {
        return rewardRate.mul(rewardsDuration);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */
    function _deposit(uint256 amount, address _to) private nonReentrant notPaused updateReward(_to) {
        require(amount > 0, "amount");
        _totalSupply = _totalSupply.add(amount);
        _balances[_to] = _balances[_to].add(amount);
        _depositedAt[_to] = block.timestamp;
        _stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(_to, amount);
    }

    function deposit(uint256 amount) override public {
        _deposit(amount, msg.sender);
    }

    function depositAll() override external {
        deposit(_stakingToken.balanceOf(msg.sender));
    }

    function withdraw(uint256 amount) override public nonReentrant updateReward(msg.sender) {
        require(amount > 0, "amount");
        require(amount <= withdrawableBalanceOf(msg.sender), "locked");
        _totalSupply = _totalSupply.sub(amount);
        _balances[msg.sender] = _balances[msg.sender].sub(amount);
        _stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function withdrawAll() override external {
        uint _withdraw = withdrawableBalanceOf(msg.sender);
        if (_withdraw > 0) {
            withdraw(_withdraw);
        }
        getReward();
    }

    function getReward() override public nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            reward = _flipToWBNB(reward);
            IBEP20(ROUTER.WETH()).safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function getRewardInBTC() public nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];

        if (reward > 0) {
            rewards[msg.sender] = 0;
            reward = _flipToWBNB(reward);

            address[] memory path = new address[](2);
            path[0] = WBNB;
            path[1] = BTCB;
            ROUTER.swapExactTokensForTokens(reward, 0, path, address(this), block.timestamp);

            reward = IBEP20(BTCB).balanceOf(address(this));

            if (reward > 0) {
              IBEP20(BTCB).safeTransfer(msg.sender, reward);
              emit RewardPaid(msg.sender, reward);
            }
        }
    }

    function getRewardInETH() public nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];

        if (reward > 0) {
            rewards[msg.sender] = 0;
            reward = _flipToWBNB(reward);

            address[] memory path = new address[](2);
            path[0] = WBNB;
            path[1] = ETH;
            ROUTER.swapExactTokensForTokens(reward, 0, path, address(this), block.timestamp);

            reward = IBEP20(ETH).balanceOf(address(this));


            if (reward > 0) {
              IBEP20(ETH).safeTransfer(msg.sender, reward);
              emit RewardPaid(msg.sender, reward);
            }
        }
    }

    function _flipToWBNB(uint amount) private returns(uint reward) {
        address wbnb = ROUTER.WETH();
        (uint rewardMerlin,) = ROUTER.removeLiquidity(
            address(_stakingToken), wbnb,
            amount, 0, 0, address(this), block.timestamp);
        address[] memory path = new address[](2);
        path[0] = address(_stakingToken);
        path[1] = wbnb;
        ROUTER.swapExactTokensForTokens(rewardMerlin, 0, path, address(this), block.timestamp);

        reward = IBEP20(wbnb).balanceOf(address(this));
    }


    function harvest() override external {}

    function info(address account) external view returns(UserInfo memory) {
        UserInfo memory userInfo;

        userInfo.balance = _balances[account];
        userInfo.principal = _balances[account];
        userInfo.available = withdrawableBalanceOf(account);

        Profit memory profit;
        (uint usd, uint merlin, uint bnb) = profitOf(account);
        profit.usd = usd;
        profit.merlin = merlin;
        profit.bnb = bnb;
        userInfo.profit = profit;

        userInfo.poolTVL = tvl();

        APY memory poolAPY;
        (usd, merlin, bnb) = apy();
        poolAPY.usd = usd;
        poolAPY.merlin = merlin;
        poolAPY.bnb = bnb;
        userInfo.poolAPY = poolAPY;

        return userInfo;
    }

    /* ========== RESTRICTED FUNCTIONS ========== */
    function setRewardsToken(address __rewardsToken) external onlyOwner {
        require(address(__rewardsToken) != address(0), "set rewards token already");
        _rewardsToken = IBEP20(__rewardsToken);
        IBEP20(_rewardsToken).safeApprove(address(ROUTER), uint(~0));
    }

    function setStakePermission(address _address, bool permission) external onlyOwner {
        _stakePermission[_address] = permission;
    }

    function stakeTo(uint256 amount, address _to) external canStakeTo {
        _deposit(amount, _to);
    }

    function notifyRewardAmount(uint256 reward) override external onlyRewardsDistribution updateReward(address(0)) {
        if (block.timestamp >= periodFinish) {
            rewardRate = reward.div(rewardsDuration);
        } else {
            uint256 remaining = periodFinish.sub(block.timestamp);
            uint256 leftover = remaining.mul(rewardRate);
            rewardRate = reward.add(leftover).div(rewardsDuration);
        }

        // Ensure the provided reward amount is not more than the balance in the contract.
        // This keeps the reward rate in the right range, preventing overflows due to
        // very high values of rewardRate in the earned and rewardsPerToken functions;
        // Reward + leftover must be less than 2^256 / 10^18 to avoid overflow.
        uint _balance = _rewardsToken.balanceOf(address(this));
        require(rewardRate <= _balance.div(rewardsDuration), "reward");

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp.add(rewardsDuration);
        emit RewardAdded(reward);
    }

    function recoverBEP20(address tokenAddress, uint256 tokenAmount) external onlyOwner {
        require(tokenAddress != address(_stakingToken) && tokenAddress != address(_rewardsToken), "tokenAddress");
        IBEP20(tokenAddress).safeTransfer(owner(), tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }

    function setRewardsDuration(uint256 _rewardsDuration) external onlyOwner {
        require(periodFinish == 0 || block.timestamp > periodFinish, "period");
        rewardsDuration = _rewardsDuration;
        emit RewardsDurationUpdated(rewardsDuration);
    }

    /* ========== MODIFIERS ========== */

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    modifier canStakeTo() {
        require(_stakePermission[msg.sender], 'auth');
        _;
    }

    function stakingToken() external override view returns (address) {
        return address(_stakingToken);
    }

    function rewardsToken() external override view returns (address) {
        return address(_rewardsToken);
    }

    function minter() external view override returns (address) {
        return address(0);
    }

    function priceShare() external view override returns (uint) {
        return 1e18;
    }

    function depositedAt(address account) external view override returns (uint) {
        return _depositedAt[account];
    }

    function sharesOf(address ) public view override returns (uint) {
        return 0;
    }

    /* ========== EVENTS ========== */

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardsDurationUpdated(uint256 newDuration);
    event Recovered(address token, uint256 amount);
}
