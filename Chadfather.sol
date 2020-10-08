// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.6.12;
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import '@openzeppelin/contracts/utils/EnumerableSet.sol';
import '@openzeppelin/contracts/math/SafeMath.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import './Chadspawn.sol';

interface IMigratorChad {
	// Perform LP token migration from legacy UniswapV2 to ChadSwap.
	// Take the current LP token address and return the new LP token address.
	// Migrator should have full access to the caller's LP token.
	// Return the new LP token address.
	//
	// XXX Migrator must have allowance access to UniswapV2 LP tokens.
	// ChadSwap must mint EXACTLY the same amount of ChadSwap LP tokens or
	// else something bad will happen. Traditional UniswapV2 does not
	// do that so be careful!
	function migrate(IERC20 token) external returns (IERC20);
}

// Chadfather is the meistress of Chad. She can make Chad and he is a fair gal.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once CHAD is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.

contract Chadfather is Ownable {
	using SafeMath for uint256;
	using SafeERC20 for IERC20;

	// Info of each user.
	struct UserInfo {
		uint256 amount; // How many LP tokens the user has provided.
		uint256 rewardDebt; // Reward debt. See explanation below.
		//
		// We do some fancy math here. Basically, any point in time, the amount of CHADs
		// entitled to a user but is pending to be distributed is:
		//
		//   pending reward = (user.amount * pool.accChadPerShare) - user.rewardDebt
		//
		// Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
		//   1. The pool's `accChadPerShare` (and `lastRewardBlock`) gets updated.
		//   2. User receives the pending reward sent to his/her address.
		//   3. User's `amount` gets updated.
		//   4. User's `rewardDebt` gets updated.
	}

	// Info of each pool.
	struct PoolInfo {
		IERC20 lpToken; // Address of LP token contract.
		uint256 allocPoint; // How many allocation points assigned to this pool. CHADs to distribute per block.
		uint256 lastRewardBlock; // Last block number that CHADs distribution occurs.
		uint256 accChadPerShare; // Accumulated CHADs per share, times 1e12. See below.
	}

	// The CHAD TOKEN!
	Chadspawn public chad;
	// Dev address.
	address public devaddr;
	// Block number when bonus CHAD period ends.
	uint256 public bonusEndBlock;
	// CHAD tokens created per block.
	uint256 public chadPerBlock;
	// farming on/off switch
	bool public farmingOn = false;
	// halving rates array
	uint256[] halvingRates;
	// Bonus muliplier for early chad makers.
	uint256 public constant BONUS_MULTIPLIER = 10;
	// The migrator contract. It has a lot of power. Can only be set through governance (owner).
	IMigratorChad public migrator;
	// 12 blocks per second, 86400 seconds per day
	// 86400/12 = 7200 blocks per day
	// 7200 * 5 = 36000 blocks per 5 days ('week')
	uint256 public constant halvingPeriod = 36000;
	// Info of each pool.
	PoolInfo[] public poolInfo;
	// Info of each user that stakes LP tokens.
	mapping(uint256 => mapping(address => UserInfo)) public userInfo;
	// Total allocation poitns. Must be the sum of all allocation points in all pools.
	uint256 public totalAllocPoint = 0;
	// The block number when CHAD mining starts.
	uint256 public farmingStartBlock;
	uint256 public farmingEndBlock;

	event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
	event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
	event EmergencyWithdraw(
		address indexed user,
		uint256 indexed pid,
		uint256 amount
	);

	constructor(
		Chadspawn _chad,
		address _devaddr,
		uint256 _chadPerBlock,
		uint256[] memory _halvingRates
	) public {
		chad = _chad;
		devaddr = _devaddr;
		chadPerBlock = _chadPerBlock;
		halvingRates = _halvingRates;
	}

	function poolLength() external view returns (uint256) {
		return poolInfo.length;
	}

	function startFarming(
		uint256 newFarmingTotalBlocks,
		uint256 newFarmingBonusBlocks
	) public onlyOwner returns (bool) {
		farmingOn = true;
		farmingStartBlock = block.number;
		farmingEndBlock = block.number + newFarmingTotalBlocks;
		bonusEndBlock = block.number + newFarmingBonusBlocks;
		return true;
	}

	function removeReceiverBurnWhitelist(address toRemove)
		public
		onlyOwner
		returns (bool)
	{
		chad.removeReceiverBurnWhitelist(toRemove);
		return true;
	}

	function removeSenderBurnWhitelist(address toRemove)
		public
		onlyOwner
		returns (bool)
	{
		chad.removeSenderBurnWhitelist(toRemove);
		return true;
	}

	function addReceiverBurnWhitelist(address toAdd)
		public
		onlyOwner
		returns (bool)
	{
		chad.addReceiverBurnWhitelist(toAdd);
		return true;
	}

	function addSenderBurnWhitelist(address toAdd)
		public
		onlyOwner
		returns (bool)
	{
		chad.addSenderBurnWhitelist(toAdd);
		return true;
	}

	function bigBurnStart(
		uint256 newBigBurnBlocks,
		uint256 newBigBurnRate,
		uint256 newBigBonusRate
	) public onlyOwner returns (bool) {
		chad.bigBurnStart(newBigBurnBlocks, newBigBurnRate, newBigBonusRate);
		return true;
	}

	function bigBurnStop() public onlyOwner returns (bool) {
		chad.bigBurnStop();
		return true;
	}

	function burnStart(uint256 newBurnRate, uint256 newBonusRate)
		public
		onlyOwner
		returns (bool)
	{
		chad.burnStart(newBurnRate, newBonusRate);
		return true;
	}

	function burnStop() public onlyOwner returns (bool) {
		chad.burnStop();
		return true;
	}

	// Add a new lp to the pool. Can only be called by the owner.
	// XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
	function add(
		uint256 _allocPoint,
		IERC20 _lpToken,
		bool _withUpdate
	) public onlyOwner {
		if (_withUpdate) {
			massUpdatePools();
		}
		uint256 lastRewardBlock = block.number > farmingStartBlock
			? block.number
			: farmingStartBlock;
		totalAllocPoint = totalAllocPoint.add(_allocPoint);
		poolInfo.push(
			PoolInfo({
				lpToken: _lpToken,
				allocPoint: _allocPoint,
				lastRewardBlock: lastRewardBlock,
				accChadPerShare: 0
			})
		);
	}

	// Update the given pool's CHAD allocation point. Can only be called by the owner.
	function set(
		uint256 _pid,
		uint256 _allocPoint,
		bool _withUpdate
	) public onlyOwner {
		if (_withUpdate) {
			massUpdatePools();
		}
		totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(
			_allocPoint
		);
		poolInfo[_pid].allocPoint = _allocPoint;
	}

	// Set the migrator contract. Can only be called by the owner.
	function setMigrator(IMigratorChad _migrator) public onlyOwner {
		migrator = _migrator;
	}

	// Migrate lp token to another lp contract. Can be called by anyone. We trust that migrator contract is good.
	function migrate(uint256 _pid) public {
		require(address(migrator) != address(0), 'migrate: no migrator');
		PoolInfo storage pool = poolInfo[_pid];
		IERC20 lpToken = pool.lpToken;
		uint256 bal = lpToken.balanceOf(address(this));
		lpToken.safeApprove(address(migrator), bal);
		IERC20 newLpToken = migrator.migrate(lpToken);
		require(bal == newLpToken.balanceOf(address(this)), 'migrate: bad');
		pool.lpToken = newLpToken;
	}

	// Return reward multiplier over the given _from to _to block.
	function getMultiplier(uint256 _from, uint256 _to)
		public
		view
		returns (uint256)
	{
		uint256 chadReward = 0;

		if (_to <= bonusEndBlock) {
			chadReward = _to.sub(_from).mul(BONUS_MULTIPLIER);
		} else if (_from >= bonusEndBlock) {
			chadReward = _to.sub(_from);
		} else {
			chadReward = bonusEndBlock.sub(_from).mul(BONUS_MULTIPLIER).add(
				_to.sub(bonusEndBlock)
			);
		}
		uint256 diff = (block.number).sub(farmingStartBlock);
		uint256 thisHalvingPeriod;
		if (diff < halvingPeriod) {
			thisHalvingPeriod = 1;
		} else if (diff < halvingPeriod.mul(2)) {
			thisHalvingPeriod = 2;
		} else if (diff < halvingPeriod.mul(3)) {
			thisHalvingPeriod = 3;
		} else if (diff < halvingPeriod.mul(4)) {
			thisHalvingPeriod = 4;
		} else {
			thisHalvingPeriod = 5;
		}
		uint256 chadRewardHalved = chadReward.div(halvingRates[thisHalvingPeriod]);
		return chadRewardHalved;
	}

	// View function to see pending CHADs on frontend.
	function pendingChad(uint256 _pid, address _user)
		external
		view
		returns (uint256)
	{
		PoolInfo storage pool = poolInfo[_pid];
		UserInfo storage user = userInfo[_pid][_user];
		uint256 accChadPerShare = pool.accChadPerShare;
		uint256 lpSupply = pool.lpToken.balanceOf(address(this));
		if (block.number > pool.lastRewardBlock && lpSupply != 0) {
			uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
			uint256 chadReward = multiplier
				.mul(chadPerBlock)
				.mul(pool.allocPoint)
				.div(totalAllocPoint);
			accChadPerShare = accChadPerShare.add(chadReward.mul(1e12).div(lpSupply));
		}
		uint256 pendingChad = user.amount.mul(accChadPerShare).div(1e12).sub(
			user.rewardDebt
		);
		return pendingChad;
	}

	// Update reward variables for all pools. Be careful of gas spending!
	function massUpdatePools() public {
		uint256 length = poolInfo.length;
		for (uint256 pid = 0; pid < length; ++pid) {
			updatePool(pid);
		}
	}

	// Update reward variables of the given pool to be up-to-date.
	function updatePool(uint256 _pid) public {
		PoolInfo storage pool = poolInfo[_pid];
		if (block.number <= pool.lastRewardBlock) {
			return;
		}
		uint256 lpSupply = pool.lpToken.balanceOf(address(this));
		if (lpSupply == 0) {
			pool.lastRewardBlock = block.number;
			return;
		}
		uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
		uint256 chadReward = multiplier.mul(chadPerBlock).mul(pool.allocPoint).div(
			totalAllocPoint
		);

		if (chadReward + chad.totalSupply() > chad.maxSupply()) {
			farmingOn = false;
		} else {
			chad.mint(devaddr, chadReward.div(10));
			// main minting
			chad.mint(address(this), chadReward);
			pool.accChadPerShare = pool.accChadPerShare.add(
				chadReward.mul(1e12).div(lpSupply)
			);
			pool.lastRewardBlock = block.number;
		}
	}

	// Deposit LP tokens to Chadfather for CHAD allocation.
	function deposit(uint256 _pid, uint256 _amount) public {
		PoolInfo storage pool = poolInfo[_pid];
		UserInfo storage user = userInfo[_pid][msg.sender];
		updatePool(_pid);
		if (user.amount > 0) {
			uint256 pending = user.amount.mul(pool.accChadPerShare).div(1e12).sub(
				user.rewardDebt
			);
			if (pending > 0) {
				safeChadTransfer(msg.sender, pending);
			}
		}
		if (_amount > 0) {
			pool.lpToken.safeTransferFrom(
				address(msg.sender),
				address(this),
				_amount
			);
			user.amount = user.amount.add(_amount);
		}
		user.rewardDebt = user.amount.mul(pool.accChadPerShare).div(1e12);
		emit Deposit(msg.sender, _pid, _amount);
	}

	// Withdraw LP tokens from Chadfather.
	function withdraw(uint256 _pid, uint256 _amount) public {
		PoolInfo storage pool = poolInfo[_pid];
		UserInfo storage user = userInfo[_pid][msg.sender];
		require(user.amount >= _amount, 'withdraw: not good');
		updatePool(_pid);
		uint256 pending = user.amount.mul(pool.accChadPerShare).div(1e12).sub(
			user.rewardDebt
		);
		if (pending > 0) {
			safeChadTransfer(msg.sender, pending);
		}
		if (_amount > 0) {
			user.amount = user.amount.sub(_amount);
			pool.lpToken.safeTransfer(address(msg.sender), _amount);
		}
		user.rewardDebt = user.amount.mul(pool.accChadPerShare).div(1e12);
		emit Withdraw(msg.sender, _pid, _amount);
	}

	// Withdraw without caring about rewards. EMERGENCY ONLY.
	function emergencyWithdraw(uint256 _pid) public {
		PoolInfo storage pool = poolInfo[_pid];
		UserInfo storage user = userInfo[_pid][msg.sender];
		pool.lpToken.safeTransfer(address(msg.sender), user.amount);
		emit EmergencyWithdraw(msg.sender, _pid, user.amount);
		user.amount = 0;
		user.rewardDebt = 0;
	}

	// Safe chad transfer function, just in case if rounding error causes pool to not have enough CHADs.
	function safeChadTransfer(address _to, uint256 _amount) internal {
		uint256 chadBal = chad.balanceOf(address(this));
		if (_amount > chadBal) {
			chad.transfer(_to, chadBal);
		} else {
			chad.transfer(_to, _amount);
		}
	}

	// Update dev address by the previous dev.
	function dev(address _devaddr) public {
		require(msg.sender == devaddr, 'dev: wut?');
		devaddr = _devaddr;
	}
}
