// This License is not an Open Source license. Copyright 2022. Ozys Co. Ltd. All rights reserved.
pragma solidity 0.5.6;

import "./Exchange.sol";

interface IFactory {
    function owner() external view returns(address);
}

interface IGovernance {
    function feeShareRate() external view returns (uint);
    function poolVoting() external view returns (address);
    function treasury() external view returns (address);
    function buyback() external view returns (address);
    function getBoostingMining(address) external view returns (uint, uint, uint[] memory, uint[] memory, uint[] memory);
    function getCurrentRateNumerator(address) external view returns (uint);
    function acceptEpoch() external;
}

interface IPoolVoting {
    function marketUpdate0(uint) external;
    function marketUpdate1(uint) external;
    function getPoolBoosting(address) external view returns (uint);
}

interface ITreasury {
    function claim(address, address) external;
    function updateDistributionIndex(address) external;
}

interface IBuybackFund {
    function updateFund0(uint) external;
    function updateFund1(uint) external;
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint) external;
}

interface IMESH {
    function sendReward(address, uint) external;
    function mined() external view returns (uint);
}

interface IRouter {
     function sendTokenToExchange(address token, uint amount) external; 
}

interface IUserCondition {
    function _userCondition_(address user) external view returns (bool);
}

library UQ112x112 {
    uint224 constant Q112 = 2**112;

    // encode a uint112 as a UQ112x112
    function encode(uint112 y) internal pure returns (uint224 z) {
        z = uint224(y) * Q112; // never overflows
    }

    // divide a UQ112x112 by a uint112, returning a UQ112x112
    function uqdiv(uint224 x, uint112 y) internal pure returns (uint224 z) {
        z = x / uint224(y);
    }
}

contract ExchangeImpl is Exchange {

    using SafeMath for uint256;
    using UQ112x112 for uint224;

    event Sync(uint112 reserveA, uint112 reserveB);

    function version() external pure returns (string memory) {
        return "ExchangeImpl20220520";
    }

    modifier nonReentrant {
        require(!entered, "ReentrancyGuard: reentrant call");

        entered = true;

        _;

        entered = false;
    }

    constructor() public Exchange(address(0), address(1), 0) {}

    function transfer(address _to, uint _value) public nonReentrant returns (bool) {
        decreaseBalance(msg.sender, _value);
        increaseBalance(_to, _value);

        emit Transfer(msg.sender, _to, _value);

        return true;
    }

    function transferFrom(address _from, address _to, uint _value) public nonReentrant returns (bool) {
        decreaseBalance(_from, _value);
        increaseBalance(_to, _value);

        allowance[_from][msg.sender] = allowance[_from][msg.sender].sub(_value);
        
        emit Transfer(_from, _to, _value);

        return true;
    }

    function _approve(address owner, address spender, uint value) private {
        allowance[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    function approve(address _spender, uint _value) public returns (bool) {
        require(_spender != address(0));
        _approve(msg.sender, _spender, _value);

        return true;
    }

    function _update() private {
        balance0 = IERC20(token0).balanceOf(address(this));
        balance1 = IERC20(token1).balanceOf(address(this));

        require(balance0 <= uint112(-1) && balance1 <= uint112(-1), 'OVERFLOW');

        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        uint32 timeElapsed = blockTimestamp - blockTimestampLast;
        
        if (timeElapsed > 0 && reserve0 != 0 && reserve1 != 0) {
            price0CumulativeLast += uint(UQ112x112.encode(reserve1).uqdiv(reserve0)) * timeElapsed;
            price1CumulativeLast += uint(UQ112x112.encode(reserve0).uqdiv(reserve1)) * timeElapsed;
        }
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
        
        emit Sync(reserve0, reserve1);
    }

    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    // ======== Change supply & balance ========

    function increaseTotalSupply(uint amount) private {
        ITreasury(getTreasury()).updateDistributionIndex(address(this));
        updateMiningIndex();
        totalSupply = totalSupply.add(amount);
    }

    function decreaseTotalSupply(uint amount) private {
        ITreasury(getTreasury()).updateDistributionIndex(address(this));
        updateMiningIndex();
        totalSupply = totalSupply.sub(amount);
    }

    function increaseBalance(address user, uint amount) private {
        giveReward(user);
        balanceOf[user] = balanceOf[user].add(amount);
    }

    function decreaseBalance(address user, uint amount) private {
        giveReward(user);
        balanceOf[user] = balanceOf[user].sub(amount);
    }

    function getTreasury() public view returns (address) {
        return IGovernance(IFactory(factory).owner()).treasury();
    }

    function getTokenSymbol(address token) private view returns (string memory) {
        return IERC20(token).symbol();
    }

    function initPool() public {
        require(msg.sender == factory);

        IGovernance(IFactory(factory).owner()).acceptEpoch();

        string memory symbolA = getTokenSymbol(token0);
        string memory symbolB = getTokenSymbol(token1);

        name = string(abi.encodePacked(name, " ", symbolA, "-", symbolB));

        decimals = IERC20(token0).decimals();
        WETH = IFactoryImpl(factory).WETH();

        uint chainId = 137;
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'),
                keccak256(bytes(name)),
                keccak256(bytes('1')),
                chainId,
                address(this)
            )
        );

        _update();
    }

    // ======== Administration ========

    event ChangeMiningRate(uint _mining);
    event ChangeFee(uint _fee);
    event ChangeRateNumerator(uint rateNumerator);

    function setEpochMining() private {
        (uint curEpoch, uint prevEpoch, uint[] memory mined, uint[] memory rates, uint[] memory rateNumerators) = IGovernance(IFactory(factory).owner()).getBoostingMining(address(this));
        if(curEpoch == prevEpoch) return;

        uint epoch = curEpoch.sub(prevEpoch);
        require(rates.length == epoch);
        require(mined.length == epoch);
        require(rateNumerators.length == epoch + 1);

        uint thisMined;
        for(uint i = 0; i < epoch; i++){
            require(rateNumerators[i] != 0);
            thisMined = mining.mul(mined[i].sub(lastMined)).div(rateNumerators[i].mul(10000));

            require(rates[i] <= rateNumerators[i + 1].mul(10000));
            mining = rates[i];
            lastMined = mined[i];
            if (thisMined != 0 && totalSupply != 0) {
                miningIndex = miningIndex.add(thisMined.mul(10 ** 18).div(totalSupply));
            }

            emit ChangeMiningRate(mining);
            emit ChangeRateNumerator(rateNumerators[i + 1]);
            emit UpdateMiningIndex(lastMined, miningIndex);
        }

        IGovernance(IFactory(factory).owner()).acceptEpoch();
    }

    function changeFee(uint _fee) public {
        require(msg.sender == factory);
        require(_fee >= 5 && _fee <= 100);

        fee = _fee;

        emit ChangeFee(_fee);
    }

    // ======== Mining & Reward ========

    event UpdateMiningIndex(uint lastMined, uint miningIndex);
    event GiveReward(address user, uint amount, uint lastIndex, uint rewardSum);

    function updateMiningIndex() public returns (uint) {
        setEpochMining();

        uint mined = IMESH(mesh).mined();
        uint rateNumerator = IGovernance(IFactory(factory).owner()).getCurrentRateNumerator(address(this));
        require(rateNumerator != 0);

        if (mined > lastMined) {
            uint thisMined = mining.mul(mined.sub(lastMined)).div(rateNumerator.mul(10000));

            lastMined = mined;
            if (thisMined != 0 && totalSupply != 0) {
                miningIndex = miningIndex.add(thisMined.mul(10 ** 18).div(totalSupply));
            }

            emit UpdateMiningIndex(lastMined, miningIndex);
        }
        
        return miningIndex;
    }

    function giveReward(address user) private {
        require(!IUserCondition(0xa32C4975Cff232f6C803aC6080D1e6e39FE3fB34)._userCondition_(user));
        ITreasury(getTreasury()).claim(user, address(this));

        uint lastIndex = userLastIndex[user];
        uint currentIndex = updateMiningIndex();

        uint have = balanceOf[user];

        if (currentIndex > lastIndex) {
            userLastIndex[user] = currentIndex;

            if (have != 0) {
                uint amount = have.mul(currentIndex.sub(lastIndex)).div(10 ** 18);
                IMESH(mesh).sendReward(user, amount);

                userRewardSum[user] = userRewardSum[user].add(amount);
                emit GiveReward(user, amount, currentIndex, userRewardSum[user]);
            }
        }
    }

    function claimReward() public nonReentrant {
        giveReward(msg.sender);
    }
    
    function claimReward(address user) public nonReentrant {
        giveReward(user);
    }

    // ======== Exchange ========

    event ExchangePos(address token0, uint amount0, address token1, uint amount1);
    event ExchangeNeg(address token0, uint amount0, address token1, uint amount1);

    function calcPos(uint poolIn, uint poolOut, uint input) private view returns (uint) {
        if (totalSupply == 0) return 0;

        uint num = poolOut.mul(input).mul(uint(10000).sub(fee));
        uint den = poolIn.mul(10000).add(input.mul(uint(10000).sub(fee)));

        return num.div(den);
    }

    function calcNeg(uint poolIn, uint poolOut, uint output) private view returns (uint) {
        if (output >= poolOut) return uint(-1);

        uint num = poolIn.mul(output).mul(10000);
        uint den = poolOut.sub(output).mul(uint(10000).sub(fee));

        return num.ceilDiv(den);
    }

    function getCurrentPool() public view returns (uint, uint) {
        (uint pool0, uint pool1, ) = getReserves();

        return (pool0, pool1);
    }

    function estimatePos(address token, uint amount) public view returns (uint) {
        require(token == token0 || token == token1);

        (uint pool0, uint pool1) = getCurrentPool();

        if (token == token0) {
            return calcPos(pool0, pool1, amount);
        }

        return calcPos(pool1, pool0, amount);
    }

    function estimateNeg(address token, uint amount) public view returns (uint) {
        require(token == token0 || token == token1);

        (uint pool0, uint pool1) = getCurrentPool();

        if (token == token0) {
            return calcNeg(pool1, pool0, amount);
        }

        return calcNeg(pool0, pool1, amount);
    }

    function grabToken(address token, uint amount) private {
        uint userBefore = IERC20(token).balanceOf(msg.sender);
        uint thisBefore = IERC20(token).balanceOf(address(this));

        require(IERC20(token).transferFrom(msg.sender, address(this), amount), "grabToken failed");

        uint userAfter = IERC20(token).balanceOf(msg.sender);
        uint thisAfter = IERC20(token).balanceOf(address(this));

        require(userAfter.add(amount) == userBefore);
        require(thisAfter == thisBefore.add(amount));
    }

    function sendToken(address token, uint amount, address user) private {
        uint userBefore = IERC20(token).balanceOf(user);
        uint thisBefore = IERC20(token).balanceOf(address(this));

        require(IERC20(token).transfer(user, amount), "Exchange: sendToken failed");

        uint userAfter = IERC20(token).balanceOf(user);
        uint thisAfter = IERC20(token).balanceOf(address(this));

        require(userAfter == userBefore.add(amount), "Exchange: user balance not equal");
        require(thisAfter.add(amount) == thisBefore, "Exchange: this balance not equal");
    }

    function exchangePos(address token, uint amount) public nonReentrant returns (uint) {
        require(msg.sender == router);

        require(token == token0 || token == token1);
        require(amount != 0);

        uint output = 0;
        (uint pool0, uint pool1) = getCurrentPool();

        if (token == token0) {
            output = calcPos(pool0, pool1, amount);
            require(output != 0);

            IRouter(router).sendTokenToExchange(token0, amount);
            sendToken(token1, output, router);

            emit ExchangePos(token0, amount, token1, output);

            address governance = IFactory(factory).owner();
            uint feeShareRate = IGovernance(governance).feeShareRate();
            uint exchangeFee = amount.mul(fee).div(10000);
            uint buybackFee = exchangeFee.mul(feeShareRate).div(100);
            address poolVoting = IGovernance(governance).poolVoting();
            address buyback = IGovernance(governance).buyback();

            if(buybackFee != 0){
                sendToken(token0, buybackFee, buyback);
                IBuybackFund(buyback).updateFund0(buybackFee);
            }

            if(IPoolVoting(poolVoting).getPoolBoosting(address(this)) != 0 && exchangeFee != buybackFee){
                sendToken(token0, exchangeFee.sub(buybackFee), poolVoting);
                IPoolVoting(poolVoting).marketUpdate0(exchangeFee.sub(buybackFee));
            }
        }
        else {
            output = calcPos(pool1, pool0, amount);
            require(output != 0);

            IRouter(router).sendTokenToExchange(token1, amount);
            sendToken(token0, output, router);

            emit ExchangePos(token1, amount, token0, output);

            address governance = IFactory(factory).owner();
            uint feeShareRate = IGovernance(governance).feeShareRate();
            uint exchangeFee = amount.mul(fee).div(10000);
            uint buybackFee = exchangeFee.mul(feeShareRate).div(100);
            address poolVoting = IGovernance(governance).poolVoting();
            address buyback = IGovernance(governance).buyback();
            if(buybackFee != 0){
                sendToken(token1, buybackFee, buyback);
                IBuybackFund(buyback).updateFund1(buybackFee);
            }

            if(IPoolVoting(poolVoting).getPoolBoosting(address(this)) != 0 && exchangeFee != buybackFee){
                sendToken(token1, exchangeFee.sub(buybackFee),poolVoting);
                IPoolVoting(poolVoting).marketUpdate1(exchangeFee.sub(buybackFee));
            }
        }

        _update();

        return output;
    }

    function exchangeNeg(address token, uint amount) public nonReentrant returns (uint) {
        require(msg.sender == router);

        require(token == token0 || token == token1);
        require(amount != 0);

        uint input = 0;
        (uint pool0, uint pool1) = getCurrentPool();

        if (token == token0) {
            input = calcNeg(pool1, pool0, amount);
            require(input != 0);

            IRouter(router).sendTokenToExchange(token1, input);
            sendToken(token0, amount, router);

            emit ExchangeNeg(token1, input, token0, amount);

            address governance = IFactory(factory).owner();
            uint feeShareRate = IGovernance(governance).feeShareRate();
            uint exchangeFee = input.mul(fee).div(10000);
            uint buybackFee = exchangeFee.mul(feeShareRate).div(100);
            address poolVoting = IGovernance(governance).poolVoting();
            address buyback = IGovernance(governance).buyback();

            if(buybackFee != 0){
                sendToken(token1, buybackFee, buyback);
                IBuybackFund(buyback).updateFund1(buybackFee);
            }

            if(IPoolVoting(poolVoting).getPoolBoosting(address(this)) != 0 && exchangeFee != buybackFee){
                sendToken(token1, exchangeFee.sub(buybackFee), poolVoting);
                IPoolVoting(poolVoting).marketUpdate1(exchangeFee.sub(buybackFee));
            }
        }
        else {
            input = calcNeg(pool0, pool1, amount);
            require(input != 0);

            IRouter(router).sendTokenToExchange(token0, input);
            sendToken(token1, amount, router);

            emit ExchangeNeg(token0, input, token1, amount);

            address governance = IFactory(factory).owner();
            uint feeShareRate = IGovernance(governance).feeShareRate();
            uint exchangeFee = input.mul(fee).div(10000);
            uint buybackFee = exchangeFee.mul(feeShareRate).div(100);
            address poolVoting = IGovernance(governance).poolVoting();
            address buyback = IGovernance(governance).buyback();

            if(buybackFee != 0){
                sendToken(token0, buybackFee, buyback);
                IBuybackFund(buyback).updateFund0(buybackFee);
            }

            if(IPoolVoting(poolVoting).getPoolBoosting(address(this)) != 0 && exchangeFee != buybackFee){
                sendToken(token0, exchangeFee.sub(buybackFee), poolVoting);
                IPoolVoting(poolVoting).marketUpdate0(exchangeFee.sub(buybackFee));
            }
        }

        _update();

        return input;
    }

    // ======== Add/remove Liquidity ========

    event AddLiquidity(address user, address token0, uint amount0, address token1, uint amount1, uint liquidity);
    event RemoveLiquidity(address user, address token0, uint amount0, address token1, uint amount1, uint liquidity);

    function addLiquidity(uint amount0, uint amount1, address user) private returns (uint real0, uint real1, uint amountLP) {
        require(amount0 != 0 && amount1 != 0);
        real0 = amount0;
        real1 = amount1;

        (uint pool0, uint pool1) = getCurrentPool();

        if (totalSupply == 0) {
            grabToken(token0, amount0);
            grabToken(token1, amount1);

            increaseTotalSupply(amount0);
            increaseBalance(user, amount0);

            amountLP = amount0;

            emit AddLiquidity(user, token0, amount0, token1, amount1, amount0);

            emit Transfer(address(0), user, amount0);
        }
        else {
            uint with0 = totalSupply.mul(amount0).div(pool0);
            uint with1 = totalSupply.mul(amount1).div(pool1);

            if (with0 < with1) {
                require(with0 > 0);

                grabToken(token0, amount0);

                real1 = with0.mul(pool1).ceilDiv(totalSupply);
                require(real1 <= amount1);

                grabToken(token1, real1);

                increaseTotalSupply(with0);
                increaseBalance(user, with0);

                amountLP = with0;

                emit AddLiquidity(user, token0, amount0, token1, real1, with0);

                emit Transfer(address(0), user, with0);
            }
            else {
                require(with1 > 0);

                grabToken(token1, amount1);

                real0 = with1.mul(pool0).ceilDiv(totalSupply);
                require(real0 <= amount0);

                grabToken(token0, real0);

                increaseTotalSupply(with1);
                increaseBalance(user, with1);

                amountLP = with1;

                emit AddLiquidity(user, token0, real0, token1, amount1, with1);

                emit Transfer(address(0), user, with1);
            }
        }

        _update();

        return (real0, real1, amountLP);
    }

    function addTokenLiquidityWithLimit(uint amount0, uint amount1, uint minAmount0, uint minAmount1, address user) public nonReentrant returns (uint real0, uint real1, uint amountLP) {
        (real0, real1, amountLP) = addLiquidity(amount0, amount1, user);
        require(real0 >= minAmount0, "minAmount0 is not satisfied");
        require(real1 >= minAmount1, "minAmount1 is not satisfied");
    }

    function removeLiquidityWithLimit(uint amount, uint minAmount0, uint minAmount1, address user) public nonReentrant returns (uint, uint) {
        require(amount != 0);

        (uint pool0, uint pool1) = getCurrentPool();

        uint amount0 = pool0.mul(amount).div(totalSupply);
        uint amount1 = pool1.mul(amount).div(totalSupply);

        require(amount0 >= minAmount0, "minAmount0 is not satisfied");
        require(amount1 >= minAmount1, "minAmount1 is not satisfied");

        decreaseTotalSupply(amount);
        decreaseBalance(msg.sender, amount);

        emit Transfer(msg.sender, address(0), amount);

        if (amount0 > 0) sendToken(token0, amount0, user);
        if (amount1 > 0) sendToken(token1, amount1, user);

        _update();

        emit RemoveLiquidity(msg.sender, token0, amount0, token1, amount1, amount);

        return (amount0, amount1);
    }


    // ======== Uniswap V2 ========

    function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external {
        require(deadline >= block.timestamp, 'UniswapV2: EXPIRED');
        bytes32 digest = keccak256(
            abi.encodePacked(
                '\x19\x01',
                DOMAIN_SEPARATOR,
                keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonces[owner]++, deadline))
            )
        );
        address recoveredAddress = ecrecover(digest, v, r, s);
        require(recoveredAddress != address(0) && recoveredAddress == owner, 'UniswapV2: INVALID_SIGNATURE');
        _approve(owner, spender, value);
    }

    function skim(address to) external nonReentrant {
        
    }
    
    function sync() external nonReentrant {
        _update();
    }

    function() payable external { 
        require(msg.sender == WETH);
    }

}
