// SPDX-License-Identifier: MIT

pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/IBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "./interface/IPancakePair.sol";
import "./interface/IPancakeFactory.sol";
import "../Bunny/contracts/interfaces/AggregatorV3Interface.sol";
import "../Bunny/contracts/interfaces/IPriceCalculator.sol";

/**
 * @dev Implementation of the {MPriceCalculatorBSC}.
 */
contract MPriceCalculatorBSC is IPriceCalculator, OwnableUpgradeable {
    using SafeMath for uint;

    struct CalcInfo {
        address WBNB;
        address CAKE;
        address MERL;
        address VAI;
        address BUSD;
        address PancakeFactory;
        address BNBPriceFeed;
        address BTCPriceFeed;
        address ETHPriceFeed;
    }

    CalcInfo public calcInfo;

    address public WBNB;
    address public CAKE;
    address public MERL;
    address public VAI;
    address public BUSD;

    IPancakeFactory private factory;

    /**
     * @dev 
     * BSC Mainnet
     * BNB/USD: 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE
     * BTC/USD: 0x264990fbd0A4796A3E3d8E37C4d5F87a3aCa5Ebf
     * ETH/USD: 0x9ef1B8c0E4F7dc8bF5719Ea496883DC6401d5b2e
     *
     * BSC Testnet
     * BNB/USD: 0x2514895c72f50D8bd4B4F9b1110F0D6bD2c97526
     * BTC/USD: 0x5741306c21795FdCBb9b265Ea0255F499DFe515C
     * ETH/USD: 0x143db3CEEfbdfe5631aDD3E50f7614B6ba708BA7
     */
    AggregatorV3Interface private bnbPriceFeed;
    AggregatorV3Interface private btcPriceFeed;
    AggregatorV3Interface private ethPriceFeed;

    /* ========== STATE VARIABLES ========== */

    mapping(address => address) private pairTokens;

    /**
     * @dev Initializes the contract with given `tokens`.
     */
    constructor(CalcInfo memory calcInfo_) public {
        WBNB = calcInfo_.WBNB;
        CAKE = calcInfo_.CAKE;
        MERL = calcInfo_.MERL;
        VAI = calcInfo_.VAI;
        BUSD = calcInfo_.BUSD;
        factory = IPancakeFactory(calcInfo_.PancakeFactory);
        bnbPriceFeed = AggregatorV3Interface(calcInfo_.BNBPriceFeed);
        btcPriceFeed = AggregatorV3Interface(calcInfo_.BTCPriceFeed);
        ethPriceFeed = AggregatorV3Interface(calcInfo_.ETHPriceFeed);

        calcInfo = calcInfo_;
    }

    /* ========== INITIALIZER ========== */

    function initialize() external initializer {
        __Ownable_init();
        setPairToken(VAI, BUSD);
    }

    /* ========== Restricted Operation ========== */

    function setPairToken(address asset, address pairToken) public onlyOwner {
        pairTokens[asset] = pairToken;
    }

    /* ========== Value Calculation ========== */

    function priceOfBNB() view public returns (uint) {
        (, int price, , ,) = bnbPriceFeed.latestRoundData();
        return uint(price).mul(1e10);
    }

    function priceOfBTC() view public returns (uint) {
        (, int price, , ,) = btcPriceFeed.latestRoundData();
        return uint(price).mul(1e10);
    }

    function priceOfETH() view public returns (uint) {
        (, int price, , ,) = ethPriceFeed.latestRoundData();
        return uint(price).mul(1e10);
    }

    function priceOfCake() view public returns (uint) {
        (, uint cakePriceInUSD) = valueOfAsset(CAKE, 1e18);
        return cakePriceInUSD;
    }

    function priceOfMerlin() view public returns (uint) {
        (, uint merlinPriceInUSD) = valueOfAsset(MERL, 1e18);
        return merlinPriceInUSD;
    }

    function pricesInUSD(address[] memory assets) public view override returns (uint[] memory) {
        uint[] memory prices = new uint[](assets.length);
        for (uint i = 0; i < assets.length; i++) {
            (, uint valueInUSD) = valueOfAsset(assets[i], 1e18);
            prices[i] = valueInUSD;
        }
        return prices;
    }

    function valueOfAsset(address asset, uint amount) public view override returns (uint valueInBNB, uint valueInUSD) {
        if (asset == address(0) || asset == WBNB) {
            valueInBNB = amount;
            valueInUSD = amount.mul(priceOfBNB()).div(1e18);
        }
        else if (keccak256(abi.encodePacked(IPancakePair(asset).symbol())) == keccak256("Cake-LP")) {
            if (IPancakePair(asset).token0() == WBNB || IPancakePair(asset).token1() == WBNB) {
                valueInBNB = amount.mul(IBEP20(WBNB).balanceOf(address(asset))).mul(2).div(IPancakePair(asset).totalSupply());
                valueInUSD = valueInBNB.mul(priceOfBNB()).div(1e18);
            } else {
                uint balanceToken0 = IBEP20(IPancakePair(asset).token0()).balanceOf(asset);
                (uint token0PriceInBNB,) = valueOfAsset(IPancakePair(asset).token0(), 1e18);

                valueInBNB = amount.mul(balanceToken0).mul(2).mul(token0PriceInBNB).div(1e18).div(IPancakePair(asset).totalSupply());
                valueInUSD = valueInBNB.mul(priceOfBNB()).div(1e18);
            }
        }
        else {
            address pairToken = pairTokens[asset] == address(0) ? WBNB : pairTokens[asset];
            address pair = factory.getPair(asset, pairToken);
            valueInBNB = IBEP20(pairToken).balanceOf(pair).mul(amount).div(IBEP20(asset).balanceOf(pair));
            if (pairToken != WBNB) {
                (uint pairValueInBNB,) = valueOfAsset(pairToken, 1e18);
                valueInBNB = valueInBNB.mul(pairValueInBNB).div(1e18);
            }
            valueInUSD = valueInBNB.mul(priceOfBNB()).div(1e18);
        }
    }
}
