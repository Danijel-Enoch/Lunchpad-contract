//SPDX-License-Identifier: Unlicense
pragma solidity >=0.7.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "./interfaces/IUniswapV2Router02.sol";
import "./interfaces/IUniswapPair.sol";

contract PresalePool is Ownable, Pausable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    IERC20 public immutable token;
    bool public publicMode = false;
    mapping(address => bool) public whitelist;
    mapping(address => uint) public invests;
    EnumerableSet.AddressSet investors;

    IUniswapV2Router02 public router = IUniswapV2Router02(0x10ED43C718714eb63d5aA57B78B54704E256024E);

    uint public maxInvestable = 100 ether;
    uint public minInvestable;
    uint public hardcap = 10000 ether;
    uint public softcap;
    bool public saleEnabled;
    bool public saleEnded;
    bool public finalized;
    uint public startTime;
    uint public endTime;

    uint public raised;

    uint public price;
    bool public claimEnabled;
    mapping(address => bool) public claimed;

    address public tokenOwner;

    address public ownerWallet = 0xe327c0F351eC6809c0339EF75e7DF1A225e90Fae;
    uint public fee = 20; // 2%
    uint public constant feeDenominator = 1000;

    bool public canWithdrawRaised;
    uint public minBnbAllocToLiquidity = 500; // 50%
    uint public minTokenAllocToLiquidity = 100; // 10%

    modifier onlyTokenOwner {
        require (msg.sender == tokenOwner, "!token owner");
        _;
    }

    constructor(
        address _token,
        uint _hardcap,
        uint _softcap,
        uint _maxInvest,
        uint _minInvest,
        uint _startTime,
        uint _endTime,
        uint _price,
        bool _isPublic,
        address _owner
    ) {
        token = IERC20(_token);
        if (_hardcap > 0) {
            hardcap = _hardcap;
            require (_softcap <= _hardcap, "!softcap");
        }
        if (softcap > 0) softcap = _softcap;
        if (_maxInvest > 0) {
            maxInvestable = _maxInvest;
            require (_minInvest <= _maxInvest, "!min investable");
        }
        minInvestable = _minInvest;
        startTime = _startTime;
        endTime = _endTime;
        price = _price;
        publicMode = _isPublic;
        tokenOwner = _owner;

        if (block.chainid == 97) {
            router = IUniswapV2Router02(0x9Ac64Cc6e4415144C455BD8E4837Fea55603e5c3);
        }
    }

    function setLimitForLiquidity(uint _bnb, uint _token) external onlyOwner {
        require (_bnb > 0 && _bnb <= feeDenominator, "invalid");
        require (_token > 0 && _token <= feeDenominator, "invalid");
        minBnbAllocToLiquidity = _bnb;
        minTokenAllocToLiquidity = _token;
    }

    function setCanWithdrawRaised(bool _flag) external onlyOwner {
        canWithdrawRaised = _flag;
    }

    function setPublicMode(bool _flag) external onlyTokenOwner {
        publicMode = _flag;
    }

    function setWhilteList(address[] memory _accounts, bool _flag) external onlyTokenOwner {
        for (uint i = 0; i < _accounts.length; i++) {
            if (whitelist[_accounts[i]] != _flag) whitelist[_accounts[i]] = _flag;
        }
    }

    function setInvestable(uint _min, uint _max) external onlyTokenOwner {
        require (_min <= _max, "invalid amount");
        minInvestable = _min;
        maxInvestable = _max;
    }

    function setCap(uint _soft, uint _hard) external onlyTokenOwner {
        require (_soft <= _hard, "invalid cap");
        softcap = _soft;
        hardcap = _hard;
    }

    function updateStartTime(uint _start) external onlyTokenOwner {
        if (saleEnabled) {
            require (block.timestamp < startTime, "sale already started");
        }
        require (block.timestamp <= _start, "invalid start time");
        startTime = _start;
    }

    function updateEndTime(uint _end) external onlyTokenOwner {
        if (_end > 0) {
            require (_end > startTime, "!end time");
            endTime = _end;
        } else endTime = type(uint).max;
    }

    function setPrice(uint _price) external onlyTokenOwner {
        require (!claimEnabled, "already in claiming");
        price = _price;
    }

    function enableSale() external onlyTokenOwner {
        saleEnabled = true;
    }

    function endSale() external onlyTokenOwner {
        saleEnded = true;
    }

    function enableClaim() external onlyTokenOwner {
        require (saleEnded, "!available");
        uint toSale = price.mul(raised).div(1e18);
        uint before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), toSale);
        require (token.balanceOf(address(this)).sub(before) >= toSale, "!transferred sale tokens");
        claimEnabled = true;
    }

    function invest() external payable {
        require (msg.value > 0, "!invest");
        _invest();
    }

    function _invest() internal whenNotPaused nonReentrant {
        require (saleEnabled, "!enabld sale");
        require (saleEnded == false, "sale ended");
        require (block.timestamp >= startTime, "!started");
        require (block.timestamp < endTime, "ended");
        if (publicMode == false) require (whitelist[msg.sender] == true, "!whitelisted");
        require (raised.add(msg.value) <= hardcap, "filled hardcap");
        require (invests[msg.sender].add(msg.value) <= maxInvestable, "exceeded invest");
        if (invests[msg.sender] == 0) {
            require (msg.value >= minInvestable, "too small invest");
        }

        invests[msg.sender] += msg.value;
        raised += msg.value;

        if (!investors.contains(msg.sender)) investors.add(msg.sender);
    }

    function claim() external nonReentrant {
        require (investors.contains(msg.sender), "!investor");
        require (claimEnabled == true, "!available");
        require (claimed[msg.sender] == false, "already claimed");

        uint claimAmount = price.mul(invests[msg.sender]).div(1e18);

        require (claimAmount <= token.balanceOf(address(this)), "Insufficient balance");

        token.safeTransfer(msg.sender, claimAmount);

        claimed[msg.sender] = true;
    }

    function multiSend() external onlyTokenOwner {
        require (claimEnabled == true, "!available");

        for (uint i = 0; i < investors.length(); i++) {
            address investor = investors.at(i);
            if (claimed[investor] == true) continue;

            uint claimAmount = price.mul(invests[investor]).div(1e18);

            require (claimAmount <= token.balanceOf(address(this)), "Insufficient balance");

            token.safeTransfer(investor, claimAmount);

            claimed[investor] = true;
        }
    }

    function finalize(uint _bnbAmount, uint _tokenAmount) external {
        require (msg.sender == owner() || msg.sender == tokenOwner, "!owner");
        require (saleEnded, "!end");
        require (!canWithdrawRaised, "!available to add liquidity");
        require (_bnbAmount >= minBnbAllocToLiquidity.mul(raised).div(feeDenominator), "!too small bnb amount for liquidity");
        require (_tokenAmount >= minTokenAllocToLiquidity.mul(token.totalSupply()).div(feeDenominator), "!too small token amount for liquidity");


        IUniswapV2Factory factory = IUniswapV2Factory(router.factory());
        IUniswapPair pair = IUniswapPair(factory.getPair(address(token), router.WETH()));
        if (address(pair) == address(0)) {
            IUniswapV2Factory(router.factory()).createPair(
                address(token),
                router.WETH()
            );
        }

        require (pair.totalSupply() == 0, "liquidity exsits");

        uint _before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), _tokenAmount);
        uint _after = token.balanceOf(address(this));
        require (_after.sub(_before) == _tokenAmount, "!token amount");

        token.approve(address(router), _tokenAmount);
        router.addLiquidityETH{value: _bnbAmount}(
            address(token),
            _tokenAmount,
            0,
            0,
            tokenOwner,
            block.timestamp
        );

        uint feeAmount = raised.mul(fee).div(feeDenominator);
        address(ownerWallet).call{value: feeAmount}("");
        address(tokenOwner).call{value: address(this).balance}("");

        finalized = true;
    }

    function withdraw() external {
        require (msg.sender == owner() || msg.sender == tokenOwner, "!owner");
        require (saleEnded, "!end");
        require (canWithdrawRaised, "!can't withdraw");

        uint feeAmount = raised.mul(fee).div(feeDenominator);
        address(ownerWallet).call{value: feeAmount}("");
        address(tokenOwner).call{value: raised.sub(feeAmount)}("");

        finalized = true;
    }

    function withdrawInStuck() external onlyOwner {
        require (finalized, "!available");
        address(msg.sender).call{value: address(this).balance}("");
        if (token.balanceOf(address(this)) > 0) {
            token.safeTransfer(msg.sender, token.balanceOf(address(this)));
        }
    }

    function claimable(address _user) external view returns(uint) {
        return price.mul(invests[_user]).div(1e18);
    }

    function getInvestors() external view returns (address[] memory, uint[] memory) {
        address[] memory investorList = new address[](investors.length());
        uint[] memory amountList = new uint[](investors.length());
        for (uint i = 0; i < investors.length(); i++) {
            investorList[i] = investors.at(i);
            amountList[i] = invests[investors.at(i)];
        }

        return (investorList, amountList);
    }

    function count() external view returns (uint) {
        return investors.length();
    }

    function saleAmount() external view returns (uint amount) {
        amount = price.mul(raised).div(1e18);
    }

    function unclaimed() external view returns (uint) {
        uint amount = 0;
        for (uint i = 0; i < investors.length(); i++) {
            if (claimed[investors.at(i)] == true) continue;
            amount += price.mul(invests[investors.at(i)]).div(1e18);
        }

        return amount;
    }

    function startedSale() external view returns (bool) {
        return (block.timestamp >= startTime) && saleEnabled;
    }

    function timestamp() external view returns (uint) {
        return block.timestamp;
    }

    function setFee(uint _fee) external onlyOwner {
        fee = _fee;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function getTokensInStuck() external onlyTokenOwner {
        uint256 _bal = token.balanceOf(address(this));
        if (_bal > 0) token.safeTransfer(msg.sender, _bal);
    }

    receive() external payable {
        // _invest();
        require (false, "!available to send BNB directly");
    }
}

contract Launchpad is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    struct PoolInfo {
        address pool;
        address token;
        string logo;
        address owner;
        uint createdAt;
    }

    mapping (address => PoolInfo) public poolMap;
    EnumerableSet.AddressSet pools;

    mapping (address => bool) public whitelist;

    constructor() {}

    function poolCount() external view returns (uint) {
        return pools.length();
    }

    function getPools(address _owner) external view returns (address[] memory) {
        uint count = _owner == address(0) ? pools.length() : 0;
        if (_owner != address(0)) {
            for (uint i = 0; i < pools.length(); i++) {
                if (poolMap[pools.at(i)].owner == _owner) count++;
            }
        }
        if (count == 0) return new address[](0);

        address[] memory poolList = new address[](count);
        uint index = 0;
        for (uint i = 0; i < pools.length(); i++) {
            if (_owner != address(0) && poolMap[pools.at(i)].owner != _owner) {
                continue;
            }
            poolList[index] = poolMap[pools.at(i)].pool;
            index++;
        }

        return poolList;
    }

    function deploy(
        address _token,
        string memory _logo,
        uint _hardcap,
        uint _softcap,
        uint _maxInvest,
        uint _minInvest,
        uint _startTime,
        uint _endTime,
        uint _price,
        bool _isPublic
    ) external {
        require (whitelist[_token], "!approved");
        require (bytes(_logo).length <= 256, "!url");

        PresalePool pool = new PresalePool(
            _token,
            _hardcap,
            _softcap,
            _maxInvest,
            _minInvest,
            _startTime,
            _endTime,
            _price,
            _isPublic,
            msg.sender
        );

        pools.add(address(pool));
        pool.transferOwnership(owner());

        poolMap[address(pool)] = PoolInfo({
            pool: address(pool),
            token: _token,
            logo: _logo,
            owner: msg.sender,
            createdAt: block.timestamp
        });
    }

    function approveToken(address _token, bool _flag) external onlyOwner {
        whitelist[_token] = _flag;
    }
}
