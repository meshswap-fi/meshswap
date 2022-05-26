// This License is not an Open Source license. Copyright 2022. Ozys Co. Ltd. All rights reserved.
pragma solidity 0.5.6;

import "./Exchange.sol";
import "./Factory.sol";

interface IExchange {
    function changeFee(uint _fee) external;
    function initPool() external;
    function exchangePos(address token, uint amount) external returns (uint);
    function exchangeNeg(address token, uint amount) external returns (uint);
    function estimatePos(address token, uint amount) external view returns (uint);
    function estimateNeg(address token, uint amount) external view returns (uint);
    function addTokenLiquidityWithLimit(uint amount0, uint amount1, uint minAmount0, uint minAmount1, address user) external;
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint) external;
}

interface IRouter {
    function approvePair(address pair, address token0, address token1) external;
}

contract FactoryImpl is Factory {
    using SafeMath for uint256;

    constructor() public Factory(address(0), address(0), address(0), address(0)) { }

    function version() public pure returns (string memory) {
        return "FactoryImpl20220322";
    }

    modifier nonReentrant {
        require(!entered, "ReentrancyGuard: reentrant call");

        entered = true;

        _;

        entered = false;
    }

    event ChangeCreateFee(uint _createFee);

    event ChangeNextOwner(address nextOwner);
    event ChangeOwner(address owner);
    event SetRouter(address router);

    function changeNextOwner(address _nextOwner) public {
        require(msg.sender == owner);
        nextOwner = _nextOwner;

        emit ChangeNextOwner(_nextOwner);
    }

    function changeOwner() public {
        require(msg.sender == nextOwner);
        owner = nextOwner;
        nextOwner = address(0);

        emit ChangeOwner(owner);
    }

    function changeCreateFee(uint _createFee) public {
        require(msg.sender == owner);
        createFee = _createFee;

        emit ChangeCreateFee(_createFee);
    }

    function changePoolFee(address token0, address token1, uint fee) public {
        require(msg.sender == owner);

        require(fee >= 5 && fee <= 100);

        address exc = tokenToPool[token0][token1];
        require(exc != address(0));

        IExchange(exc).changeFee(fee);
    }

    function setRouter(address _router) public {
        require(msg.sender == owner);
        router = _router;

        emit SetRouter(_router);
    }
    // ======== Create Pool ========

    event CreatePool(address token0, uint amount0, address token1, uint amount1, uint fee, address exchange, uint exid);

    function createPool(address token0, uint amount0, address token1, uint amount1, uint fee, bool isETH) private {
        require(amount0 != 0 && amount1 != 0);
        require(tokenToPool[token0][token1] == address(0), "Pool already exists");
        require(token0 != address(0));
        require(fee >= 5 && fee <= 100);

        if (createFee != 0) {
            require(IERC20(mesh).transferFrom(msg.sender, address(this), createFee));
            IERC20(mesh).burn(createFee);
        }

        Exchange exc = new Exchange(token0, token1, fee);

        poolExist[address(exc)] = true;
        IExchange(address(exc)).initPool();
        pools.push(address(exc));

        tokenToPool[token0][token1] = address(exc);
        tokenToPool[token1][token0] = address(exc);

        if (!isETH) {
            IERC20(token0).transferFrom(msg.sender, address(this), amount0);
        }
        IERC20(token1).transferFrom(msg.sender, address(this), amount1);

        IERC20(token0).approve(address(exc), amount0);
        IERC20(token1).approve(address(exc), amount1);

        IExchange(address(exc)).addTokenLiquidityWithLimit(amount0, amount1, 1, 1, msg.sender);
        IRouter(router).approvePair(address(exc), token0, token1);

        emit CreatePool(token0, amount0, token1, amount1, fee, address(exc), pools.length - 1);
    }

    function createETHPool(address token, uint amount, uint fee) public payable nonReentrant {
        uint amountWETH = msg.value;
        IWETH(WETH).deposit.value(msg.value)();
        createPool(WETH, amountWETH, token, amount, fee, true);
    }

    function createTokenPool(address token0, uint amount0, address token1, uint amount1, uint fee) public nonReentrant {
        require(token0 != token1);
        require(token1 != WETH);

        createPool(token0, amount0, token1, amount1, fee, false);
    }

    // ======== API ========

    function getPoolCount() public view returns (uint) {
        return pools.length;
    }

    function getPoolAddress(uint idx) public view returns (address) {
        require(idx < pools.length);
        return pools[idx];
    }

    // ======== For Uniswap Compatible ========

    function getPair(address tokenA, address tokenB) public view returns (address pair) {
        return tokenToPool[tokenA][tokenB];
    }

    function allPairsLength() external view returns (uint) {
        return getPoolCount();
    }

    function allPairs(uint idx) external view returns (address pair) {
        pair = getPoolAddress(idx);
    }

    
    function() payable external { revert(); }
}
