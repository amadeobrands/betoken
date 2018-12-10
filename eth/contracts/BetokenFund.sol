pragma solidity ^0.4.24;

import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/utils/ReentrancyGuard.sol";
import "./tokens/minime/MiniMeToken.sol";
import "./KyberNetwork.sol";
import "./Utils.sol";
import "./BetokenProxy.sol";

/**
 * @title The main smart contract of the Betoken hedge fund.
 * @author Zefram Lou (Zebang Liu)
 */
contract BetokenFund is Ownable, Utils, ReentrancyGuard, TokenController {
  using SafeMath for uint256;

  enum CyclePhase { Intermission, Manage }

  struct Investment {
    address tokenAddress;
    uint256 cycleNumber;
    uint256 stake;
    uint256 tokenAmount;
    uint256 buyPrice; // token buy price in 18 decimals in DAI
    uint256 sellPrice; // token sell price in 18 decimals in DAI
    bool isSold;
  }

  /**
   * @notice Executes function only during the given cycle phase.
   * @param phase the cycle phase during which the function may be called
   */
  modifier during(CyclePhase phase) {
    require(cyclePhase == phase);
    _;
  }

  /**
   * @notice Checks if `token` is a valid token.
   * @param token the token's address
   */
  modifier isValidToken(address token) {
    if (token != address(ETH_TOKEN_ADDRESS)) {
      ERC20Detailed _token = ERC20Detailed(token);
      require(_token.totalSupply() > 0);
      require(_token.decimals() >= MIN_DECIMALS);
    }
    _;
  }

  /**
   * @notice Checks if the fund is ready for upgrading to the next version
   */
  modifier readyForUpgrade {
    
    _;
  }

  uint256 constant MAX_DONATION = 100 * (10 ** 18); // max donation is 100 DAI
  uint256 constant MIN_KRO_PRICE = 25 * (10 ** 17); // 1 KRO >= 2.5 DAI
  uint256 constant REFERRAL_BONUS = 10 * (10 ** 16); // 10% bonus for getting referred
  address constant DAI_ADDR = 0x89d24A6b4CcB1B6fAA2625fE562bDD9a23260359;
  address constant KYBER_ADDR = 0x818E6FECD516Ecc3849DAf6845e3EC868087B755;
  address constant KRO_ADDR = 0x13c03e7a1C944Fa87ffCd657182616420C6ea1F9;

  // Address of the share token contract.
  address public shareTokenAddr;

  // Address of the BetokenProxy contract
  address public proxyAddr;

  // Address to which the developer fees will be paid.
  address public developerFeeAccount;

  // Address of the previous version of BetokenFund.
  address public previousVersion;

  // Address of the next version of BetokenFund.
  address public nextVersion;

  // The number of the current investment cycle.
  uint256 public cycleNumber;

  // The amount of funds held by the fund.
  uint256 public totalFundsInDAI;

  // The start time for the current investment cycle phase, in seconds since Unix epoch.
  uint256 public startTimeOfCyclePhase;

  // The proportion of the fund that gets distributed to Kairo holders every cycle. Fixed point decimal.
  uint256 public commissionRate;

  // The proportion of contract balance that gets distributed to Kairo holders every cycle. Fixed point decimal.
  uint256 public assetFeeRate;

  // The proportion of contract balance that goes the the devs every cycle. Fixed point decimal.
  uint256 public developerFeeRate;

  // The proportion of funds that goes the the devs during withdrawals. Fixed point decimal.
  uint256 public exitFeeRate;

  // Amount of Kairo rewarded to the user who calls a phase transition/investment handling function
  uint256 public functionCallReward;

  // Total amount of commission unclaimed by managers
  uint256 public totalCommissionLeft;

  // Stores the lengths of each cycle phase in seconds.
  uint256[2] phaseLengths;

  // The last cycle where a user redeemed commission.
  mapping(address => uint256) public lastCommissionRedemption;

  // List of investments in the current cycle.
  mapping(address => Investment[]) public userInvestments;

  // Total commission to be paid in a certain cycle
  mapping(uint256 => uint256) public totalCommissionOfCycle;

  // The block number at which the RedeemCommission phase started for the given cycle
  mapping(uint256 => uint256) public commissionPhaseStartBlock;

  // The current cycle phase.
  CyclePhase public cyclePhase;

  // Contract instances
  MiniMeToken internal cToken;
  MiniMeToken internal sToken;
  KyberNetwork internal kyber;
  ERC20Detailed internal dai;
  BetokenProxy internal proxy;

  event ChangedPhase(uint256 indexed _cycleNumber, uint256 indexed _newPhase, uint256 _timestamp);

  event Deposit(uint256 indexed _cycleNumber, address indexed _sender, address _tokenAddress, uint256 _tokenAmount, uint256 _daiAmount, uint256 _timestamp);
  event Withdraw(uint256 indexed _cycleNumber, address indexed _sender, address _tokenAddress, uint256 _tokenAmount, uint256 daiAmount, uint256 _timestamp);

  event CreatedInvestment(uint256 indexed _cycleNumber, address indexed _sender, uint256 _id, address _tokenAddress, uint256 _stakeInWeis, uint256 _buyPrice, uint256 _costDAIAmount);
  event SoldInvestment(uint256 indexed _cycleNumber, address indexed _sender, uint256 _investmentId, uint256 _receivedKairos, uint256 _sellPrice, uint256 _earnedDAIAmount);

  event ROI(uint256 indexed _cycleNumber, uint256 _beforeTotalFunds, uint256 _afterTotalFunds);
  event CommissionPaid(uint256 indexed _cycleNumber, address indexed _sender, uint256 _commission);
  event TotalCommissionPaid(uint256 indexed _cycleNumber, uint256 _totalCommissionInDAI);

  event Register(address indexed _manager, uint256 indexed _block, uint256 _donationInDAI);

  /**
   * Meta functions
   */

  constructor(
    address _sTokenAddr,
    address _proxyAddr,
    address _developerFeeAccount,
    uint256[2] _phaseLengths,
    uint256 _commissionRate,
    uint256 _assetFeeRate,
    uint256 _developerFeeRate,
    uint256 _exitFeeRate,
    uint256 _functionCallReward,
    address _previousVersion
  )
    public
  {
    require(_commissionRate.add(_developerFeeRate) < 10**18);

    shareTokenAddr = _sTokenAddr;
    proxyAddr = _proxyAddr;
    cToken = MiniMeToken(KRO_ADDR);
    sToken = MiniMeToken(_sTokenAddr);
    kyber = KyberNetwork(KYBER_ADDR);
    dai = ERC20Detailed(DAI_ADDR);

    developerFeeAccount = _developerFeeAccount;
    phaseLengths = _phaseLengths;
    commissionRate = _commissionRate;
    assetFeeRate = _assetFeeRate;
    developerFeeRate = _developerFeeRate;
    exitFeeRate = _exitFeeRate;
    cyclePhase = CyclePhase.Intermission;
    cycleNumber = 1;
    startTimeOfCyclePhase = now;
    functionCallReward = _functionCallReward;

    previousVersion = _previousVersion;
  }

  /**
   * Upgrading functions
   */

  function migrateOwnedContractsToNextVersion() public readyForUpgrade {
    cToken.transferOwnership(nextVersion);
    sToken.transferOwnership(nextVersion);
    proxy.updateBetokenFundAddress();
  }

  function transferAssetToNextVersion(address _assetAddress) public readyForUpgrade isValidToken(_assetAddress) {
    if (_assetAddress == address(ETH_TOKEN_ADDRESS)) {
      nextVersion.transfer(address(this).balance);
    } else {
      ERC20Detailed token = ERC20Detailed(_assetAddress);
      token.transfer(nextVersion, token.balanceOf(address(this)));
    }
  }

  /**
   * Getters
   */

  /**
   * @notice Returns the length of the user's investments array.
   * @return length of the user's investments array
   */
  function investmentsCount(address _userAddr) public view returns(uint256 _count) {
    return userInvestments[_userAddr].length;
  }

  /**
   * @notice Returns the phaseLengths array.
   * @return the phaseLengths array
   */
  function getPhaseLengths() public view returns(uint256[2] _phaseLengths) {
    return phaseLengths;
  }

  /**
   * Parameter setters
   */

  /**
   * @notice Changes the address to which the developer fees will be sent. Only callable by owner.
   * @param _newAddr the new developer fee address
   */
  function changeDeveloperFeeAccount(address _newAddr) public onlyOwner {
    require(_newAddr != address(0) && _newAddr != address(this));
    developerFeeAccount = _newAddr;
  }

  /**
   * @notice Changes the proportion of fund balance sent to the developers each cycle. May only decrease. Only callable by owner.
   * @param _newProp the new proportion, fixed point decimal
   */
  function changeDeveloperFeeRate(uint256 _newProp) public onlyOwner {
    require(_newProp < PRECISION);
    require(_newProp < developerFeeRate);
    developerFeeRate = _newProp;
  }

  /**
   * @notice Changes exit fee rate. May only decrease. Only callable by owner.
   * @param _newProp the new proportion, fixed point decimal
   */
  function changeExitFeeRate(uint256 _newProp) public onlyOwner {
    require(_newProp < PRECISION);
    require(_newProp < exitFeeRate);
    exitFeeRate = _newProp;
  }

  

  /**
   * @notice Moves the fund to the next phase in the investment cycle.
   */
  function nextPhase()
    public
  {
    require(now >= startTimeOfCyclePhase.add(phaseLengths[uint(cyclePhase)]));

    if (cyclePhase == CyclePhase.Manage) {
      // Start new cycle
      cycleNumber = cycleNumber.add(1);

      // Burn any Kairo left in BetokenFund's account
      require(cToken.destroyTokens(address(this), cToken.balanceOf(address(this))));

      __handleFees();

      commissionPhaseStartBlock[cycleNumber] = block.number;
    }

    cyclePhase = CyclePhase(addmod(uint(cyclePhase), 1, 2));
    startTimeOfCyclePhase = now;

    // Reward caller
    cToken.generateTokens(msg.sender, functionCallReward);

    emit ChangedPhase(cycleNumber, uint(cyclePhase), now);
  }

  function kairoPrice() public view returns (uint256 _kairoPrice) {
    if (cToken.totalSupply() == 0) {return 0;}
    uint256 controlPerKairo = totalFundsInDAI.mul(PRECISION).div(cToken.totalSupply());
    if (controlPerKairo < MIN_KRO_PRICE) {
      // keep price above minimum price
      return MIN_KRO_PRICE;
    }
    return controlPerKairo;
  }

  function registerWithDAI(uint256 _donationInDAI, address _referrer) public nonReentrant {
    require(dai.transferFrom(msg.sender, this, _donationInDAI), "Failed DAI transfer to IAO");
    __register(_donationInDAI, _referrer);
  }


  function registerWithETH(address _referrer) public payable nonReentrant {
    uint256 receivedDAI;
    uint256 _;

    // trade ETH for DAI
    (,receivedDAI,_) = __kyberTrade(ETH_TOKEN_ADDRESS, msg.value, dai);
    
    // if DAI value is greater than maximum allowed, return excess DAI to msg.sender
    if (receivedDAI > MAX_DONATION) {
      require(dai.transfer(msg.sender, receivedDAI.sub(MAX_DONATION)), "Excess DAI transfer failed");
      receivedDAI = MAX_DONATION;
    }

    // register new manager
    __register(receivedDAI, _referrer);
  }

  // _donationInTokens should use the token's precision
  function registerWithToken(address _token, uint256 _donationInTokens, address _referrer) public nonReentrant {
    require(_token != address(0) && _token != address(ETH_TOKEN_ADDRESS) && _token != DAI_ADDR, "Invalid token");
    ERC20Detailed token = ERC20Detailed(_token);
    require(token.totalSupply() > 0, "Zero token supply");

    uint256 receivedDAI;
    uint256 _;

    (,receivedDAI,_) = __kyberTrade(token, _donationInTokens, dai);

    // if DAI value is greater than maximum allowed, return excess DAI to msg.sender
    if (receivedDAI > MAX_DONATION) {
      require(dai.transfer(msg.sender, receivedDAI.sub(MAX_DONATION)), "Excess DAI transfer failed");
      receivedDAI = MAX_DONATION;
    }

    // register new manager
    __register(receivedDAI, _referrer);
  }


  /**
   * Intermission phase functions
   */

   /**
   * @notice Deposit Ether into the fund. Ether will be converted into DAI.
   */
  function depositEther()
    public
    payable
    during(CyclePhase.Intermission)
    nonReentrant
  {
    // Buy DAI with ETH
    uint256 actualDAIDeposited;
    uint256 actualETHDeposited;
    (, actualDAIDeposited, actualETHDeposited) = __kyberTrade(ETH_TOKEN_ADDRESS, msg.value, dai);

    // Send back leftover ETH
    uint256 leftOverETH = msg.value.sub(actualETHDeposited);
    if (leftOverETH > 0) {
      msg.sender.transfer(leftOverETH);
    }

    // Register investment
    __deposit(actualDAIDeposited);

    // Emit event
    emit Deposit(cycleNumber, msg.sender, ETH_TOKEN_ADDRESS, actualETHDeposited, actualDAIDeposited, now);
  }

  function depositDAI(uint256 _daiAmount)
    public
    during(CyclePhase.Intermission)
    nonReentrant
  {
    require(dai.transferFrom(msg.sender, this, _daiAmount));

    // Register investment
    __deposit(_daiAmount);

    // Emit event
    emit Deposit(cycleNumber, msg.sender, DAI_ADDR, _daiAmount, _daiAmount, now);
  }

  /**
   * @notice Deposit ERC20 tokens into the fund. Tokens will be converted into DAI.
   * @param _tokenAddr the address of the token to be deposited
   * @param _tokenAmount The amount of tokens to be deposited. May be different from actual deposited amount.
   */
  function depositToken(address _tokenAddr, uint256 _tokenAmount)
    public
    during(CyclePhase.Intermission)
    isValidToken(_tokenAddr)
    nonReentrant
  {
    require(_tokenAddr != DAI_ADDR && _tokenAddr != address(ETH_TOKEN_ADDRESS));

    ERC20Detailed token = ERC20Detailed(_tokenAddr);

    require(token.transferFrom(msg.sender, this, _tokenAmount));

    // Convert token into DAI
    uint256 actualDAIDeposited;
    uint256 actualTokenDeposited;
    (, actualDAIDeposited, actualTokenDeposited) = __kyberTrade(token, _tokenAmount, dai);

    // Give back leftover tokens
    uint256 leftOverTokens = _tokenAmount.sub(actualTokenDeposited);
    if (leftOverTokens > 0) {
      require(token.transfer(msg.sender, leftOverTokens));
    }

    // Register investment
    __deposit(actualDAIDeposited);

    // Emit event
    emit Deposit(cycleNumber, msg.sender, _tokenAddr, actualTokenDeposited, actualDAIDeposited, now);
  }


  /**
   * @notice Withdraws Ether by burning Shares.
   * @param _amountInDAI Amount of funds to be withdrawn expressed in DAI. Fixed-point decimal. May be different from actual amount.
   */
  function withdrawEther(uint256 _amountInDAI)
    public
    during(CyclePhase.Intermission)
    nonReentrant
  {
    // Buy ETH
    uint256 actualETHWithdrawn;
    uint256 actualDAIWithdrawn;
    (, actualETHWithdrawn, actualDAIWithdrawn) = __kyberTrade(dai, _amountInDAI, ETH_TOKEN_ADDRESS);

    __withdraw(actualDAIWithdrawn);

    // Transfer Ether to user
    uint256 exitFee = actualETHWithdrawn.mul(exitFeeRate).div(PRECISION);
    developerFeeAccount.transfer(exitFee);
    actualETHWithdrawn = actualETHWithdrawn.sub(exitFee);

    msg.sender.transfer(actualETHWithdrawn);

    // Emit event
    emit Withdraw(cycleNumber, msg.sender, ETH_TOKEN_ADDRESS, actualETHWithdrawn, actualDAIWithdrawn, now);
  }

  /**
   * @notice Withdraws funds by burning Shares, and converts the funds into the specified token using Kyber Network.
   * @param _tokenAddr the address of the token to be withdrawn into the caller's account
   * @param _amountInDAI The amount of funds to be withdrawn expressed in DAI. Fixed-point decimal. May be different from actual amount.
   */
  function withdrawToken(address _tokenAddr, uint256 _amountInDAI)
    public
    during(CyclePhase.Intermission)
    isValidToken(_tokenAddr)
    nonReentrant
  {
    require(_tokenAddr != DAI_ADDR && _tokenAddr != address(ETH_TOKEN_ADDRESS));

    ERC20Detailed token = ERC20Detailed(_tokenAddr);

    // Convert DAI into desired tokens
    uint256 actualTokenWithdrawn;
    uint256 actualDAIWithdrawn;
    (, actualTokenWithdrawn, actualDAIWithdrawn) = __kyberTrade(dai, _amountInDAI, token);

    __withdraw(actualDAIWithdrawn);

    // Transfer tokens to user
    uint256 exitFee = actualTokenWithdrawn.mul(exitFeeRate).div(PRECISION);
    token.transfer(developerFeeAccount, exitFee);
    actualTokenWithdrawn = actualTokenWithdrawn.sub(exitFee);
    
    token.transfer(msg.sender, actualTokenWithdrawn);

    // Emit event
    emit Withdraw(cycleNumber, msg.sender, _tokenAddr, actualTokenWithdrawn, actualDAIWithdrawn, now);
  }

  function withdrawDAI(uint256 _amountInDAI)
    public
    during(CyclePhase.Intermission)
    nonReentrant
  {
    __withdraw(_amountInDAI);

    // Transfer DAI to user
    uint256 exitFee = _amountInDAI.mul(exitFeeRate).div(PRECISION);
    dai.transfer(developerFeeAccount, exitFee);
    uint256 actualDAIWithdrawn = _amountInDAI.sub(exitFee);
    dai.transfer(msg.sender, actualDAIWithdrawn);

    // Emit event
    emit Withdraw(cycleNumber, msg.sender, DAI_ADDR, actualDAIWithdrawn, actualDAIWithdrawn, now);
  }

  /**
   * @notice Redeems commission.
   */
  function redeemCommission()
    public
    during(CyclePhase.Intermission)
    nonReentrant
  {
    uint256 commission = __redeemCommission();

    // Transfer the commission in DAI
    dai.transfer(msg.sender, commission);
  }

  /**
   * @notice Redeems commission in shares.
   */
  function redeemCommissionInShares()
    public
    during(CyclePhase.Intermission)
    nonReentrant
  {
    uint256 commission = __redeemCommission();    

    // Deposit commission into fund
    __deposit(commission);

    // Emit deposit event
    emit Deposit(cycleNumber, msg.sender, DAI_ADDR, commission, commission, now);
  }

  function __redeemCommission() internal returns (uint256 _commission) {
    require(lastCommissionRedemption[msg.sender] < cycleNumber);
    for (uint256 cycle = lastCommissionRedemption[msg.sender].add(1); cycle <= cycleNumber; cycle = cycle.add(1)) {
      _commission = _commission.add(totalCommissionOfCycle[cycle].mul(cToken.balanceOfAt(msg.sender, commissionPhaseStartBlock[cycle]))
      .div(cToken.totalSupplyAt(commissionPhaseStartBlock[cycle])));
    }

    lastCommissionRedemption[msg.sender] = cycleNumber;
    totalCommissionLeft = totalCommissionLeft.sub(_commission);
    delete userInvestments[msg.sender];

    emit CommissionPaid(cycleNumber, msg.sender, _commission);
  }

  /**
   * @notice Sells tokens left over due to manager not selling or KyberNetwork not having enough demand. Callable by anyone. Money goes to developer.
   * @param _tokenAddr address of the token to be sold
   */
  function sellLeftoverToken(address _tokenAddr)
    public
    during(CyclePhase.Intermission)
    isValidToken(_tokenAddr)
    nonReentrant
  {
    uint256 beforeBalance = getBalance(dai, this);
    ERC20Detailed token = ERC20Detailed(_tokenAddr);
    __kyberTrade(token, getBalance(token, this), dai);
    dai.transfer(developerFeeAccount, getBalance(dai, this).sub(beforeBalance));
  }


  /**
   * Manage phase functions
   */

  /**
   * @notice Creates a new investment investment for an ERC20 token.
   * @param _tokenAddress address of the ERC20 token contract
   * @param _stake amount of Kairos to be staked in support of the investment
   * @param _minPrice the minimum price for the trade
   * @param _maxPrice the maximum price for the trade
   */
  function createInvestment(
    address _tokenAddress,
    uint256 _stake,
    uint256 _minPrice,
    uint256 _maxPrice
  )
    public
    during(CyclePhase.Manage)
    isValidToken(_tokenAddress)
    nonReentrant
  {
    require(_minPrice <= _maxPrice);
    require(_stake > 0);
    ERC20Detailed token = ERC20Detailed(_tokenAddress);

    // Collect stake
    require(cToken.generateTokens(address(this), _stake));
    require(cToken.destroyTokens(msg.sender, _stake));

    // Add investment to list
    userInvestments[msg.sender].push(Investment({
      tokenAddress: _tokenAddress,
      cycleNumber: cycleNumber,
      stake: _stake,
      tokenAmount: 0,
      buyPrice: 0,
      sellPrice: 0,
      isSold: false
    }));

    // Invest
    uint256 beforeTokenAmount = getBalance(token, this);
    uint256 beforeDAIBalance = getBalance(dai, this);
    uint256 investmentId = investmentsCount(msg.sender).sub(1);
    __handleInvestment(investmentId, _minPrice, _maxPrice, true);
    userInvestments[msg.sender][investmentId].tokenAmount = getBalance(token, this).sub(beforeTokenAmount);

    // Emit event
    emit CreatedInvestment(cycleNumber, msg.sender, investmentsCount(msg.sender).sub(1), _tokenAddress, _stake, userInvestments[msg.sender][investmentId].buyPrice, beforeDAIBalance.sub(getBalance(dai, this)));
  }

  /**
   * @notice Called by user to sell the assets an investment invested in. Returns the staked Kairo plus rewards/penalties to the user.
   * @dev When selling only part of an investment, the old investment would be "fully" sold and a new investment would be created with
   *   the original buy price and however much tokens that are not sold.
   * @param _investmentId the ID of the investment
   * @param _tokenAmount the amount of tokens to be sold
   * @param _minPrice the minimum price for the trade
   * @param _maxPrice the maximum price for the trade
   */
  function sellInvestmentAsset(
    uint256 _investmentId,
    uint256 _tokenAmount,
    uint256 _minPrice,
    uint256 _maxPrice
  )
    public
    during(CyclePhase.Manage)
    nonReentrant
  {
    Investment storage investment = userInvestments[msg.sender][_investmentId];
    require(investment.buyPrice > 0 && investment.cycleNumber == cycleNumber && !investment.isSold);
    require(_tokenAmount > 0 && _tokenAmount <= investment.tokenAmount);
    require(_minPrice <= _maxPrice);

    // Create new investment for leftover tokens
    bool isPartialSell = false;
    uint256 stakeOfSoldTokens = investment.stake.mul(_tokenAmount).div(investment.tokenAmount);
    if (_tokenAmount != investment.tokenAmount) {
      isPartialSell = true;
      userInvestments[msg.sender].push(Investment({
        tokenAddress: investment.tokenAddress,
        cycleNumber: cycleNumber,
        stake: investment.stake.sub(stakeOfSoldTokens),
        tokenAmount: investment.tokenAmount.sub(_tokenAmount),
        buyPrice: investment.buyPrice,
        sellPrice: 0,
        isSold: false
      }));
      investment.tokenAmount = _tokenAmount;
    }
    
    // Update investment info
    investment.isSold = true;

    // Sell asset
    uint256 beforeDAIBalance = getBalance(dai, this);
    uint256 beforeTokenBalance = getBalance(ERC20Detailed(investment.tokenAddress), this);
    __handleInvestment(_investmentId, _minPrice, _maxPrice, false);
    if (isPartialSell) {
      // If only part of _tokenAmount was successfully sold, put the unsold tokens in the new investment
      userInvestments[msg.sender][investmentsCount(msg.sender).sub(1)].tokenAmount = userInvestments[msg.sender][investmentsCount(msg.sender).sub(1)].tokenAmount.add(_tokenAmount.sub(beforeTokenBalance.sub(getBalance(ERC20Detailed(investment.tokenAddress), this))));
    }

    // Return Kairo
    uint256 receiveKairoAmount = stakeOfSoldTokens.mul(investment.sellPrice.div(investment.buyPrice));
    if (receiveKairoAmount > stakeOfSoldTokens) {
      cToken.transfer(msg.sender, stakeOfSoldTokens);
      cToken.generateTokens(msg.sender, receiveKairoAmount.sub(stakeOfSoldTokens));
    } else {
      cToken.transfer(msg.sender, receiveKairoAmount);
      require(cToken.destroyTokens(address(this), stakeOfSoldTokens.sub(receiveKairoAmount)));
    }
    
    // Emit event
    if (isPartialSell) {
      Investment storage newInvestment = userInvestments[msg.sender][investmentsCount(msg.sender).sub(1)];
      emit CreatedInvestment(
        cycleNumber, msg.sender, investmentsCount(msg.sender).sub(1),
        newInvestment.tokenAddress, newInvestment.stake, newInvestment.buyPrice,
        newInvestment.buyPrice.mul(newInvestment.tokenAmount).div(10 ** getDecimals(ERC20Detailed(newInvestment.tokenAddress))));
    }
    emit SoldInvestment(cycleNumber, msg.sender, _investmentId, receiveKairoAmount, investment.sellPrice, getBalance(dai, this).sub(beforeDAIBalance));
  }


  /**
   * Internal use functions
   */

  // MiniMe TokenController functions, not used right now
  /**
   * @notice Called when `_owner` sends ether to the MiniMe Token contract
   * @param _owner The address that sent the ether to create tokens
   * @return True if the ether is accepted, false if it throws
   */
  function proxyPayment(address _owner) public payable returns(bool) {
    return false;
  }

  /**
   * @notice Notifies the controller about a token transfer allowing the
   *  controller to react if desired
   * @param _from The origin of the transfer
   * @param _to The destination of the transfer
   * @param _amount The amount of the transfer
   * @return False if the controller does not authorize the transfer
   */
  function onTransfer(address _from, address _to, uint _amount) public returns(bool) {
    return true;
  }

  /// @notice Notifies the controller about an approval allowing the
  ///  controller to react if desired
  /// @param _owner The address that calls `approve()`
  /// @param _spender The spender in the `approve()` call
  /// @param _amount The amount in the `approve()` call
  /// @return False if the controller does not authorize the approval
  function onApprove(address _owner, address _spender, uint _amount) public
      returns(bool) {
    return true;
  }

  function __register(uint256 _donationInDAI, address _referrer) internal {
    require(_donationInDAI > 0 && _donationInDAI <= MAX_DONATION, "Donation out of range");
    require(_referrer != msg.sender, "Can't refer self");

    MiniMeToken kro = MiniMeToken(KRO_ADDR);
    require(kro.balanceOf(msg.sender) == 0, "Already joined"); // each address can only join the IAO once

    // mint KRO for msg.sender
    uint256 kroPrice = kairoPrice();
    uint256 kroAmount = _donationInDAI.mul(kroPrice).div(PRECISION);
    require(kro.generateTokens(msg.sender, kroAmount), "Failed minting");

    // mint KRO for referral program
    if (_referrer != address(0) && kro.balanceOf(_referrer) > 0) {
      uint256 bonusAmount = kroAmount.mul(REFERRAL_BONUS).div(PRECISION);
      require(kro.generateTokens(msg.sender, bonusAmount), "Failed minting sender bonus");
      require(kro.generateTokens(_referrer, bonusAmount), "Failed minting referrer bonus");
    }

    // transfer DAI to developerFeeAccount
    require(dai.transfer(developerFeeAccount, _donationInDAI), "Failed DAI transfer to developerFeeAccount");
    
    // emit events
    emit Register(msg.sender, block.number, _donationInDAI);
  }

  function __deposit(uint256 _depositDAIAmount) internal {
    // Register investment and give shares
    if (sToken.totalSupply() == 0 || totalFundsInDAI == 0) {
      sToken.generateTokens(msg.sender, _depositDAIAmount);
    } else {
      sToken.generateTokens(msg.sender, _depositDAIAmount.mul(sToken.totalSupply()).div(totalFundsInDAI));
    }
    totalFundsInDAI = totalFundsInDAI.add(_depositDAIAmount);
  }

  function __withdraw(uint256 _withdrawDAIAmount) internal {
    // Burn Shares
    sToken.destroyTokens(msg.sender, _withdrawDAIAmount.mul(sToken.totalSupply()).div(totalFundsInDAI));
    totalFundsInDAI = totalFundsInDAI.sub(_withdrawDAIAmount);
  }

  /**
   * @notice Handles and investment by doing the necessary trades using __kyberTrade()
   * @param _investmentId the ID of the investment to be handled
   * @param _minPrice the minimum price for the trade
   * @param _maxPrice the maximum price for the trade
   * @param _buy whether to buy or sell the given investment
   */
  function __handleInvestment(uint256 _investmentId, uint256 _minPrice, uint256 _maxPrice, bool _buy) internal {
    Investment storage investment = userInvestments[msg.sender][_investmentId];
    uint256 srcAmount;
    uint256 dInS;
    uint256 sInD;
    if (_buy) {
      srcAmount = totalFundsInDAI.mul(investment.stake).div(cToken.totalSupply());
    } else {
      srcAmount = investment.tokenAmount;
    }
    ERC20Detailed token = ERC20Detailed(investment.tokenAddress);
    if (_buy) {
      (dInS, sInD,) = __kyberTrade(dai, srcAmount, token);
      require(_minPrice <= dInS && dInS <= _maxPrice);
      investment.buyPrice = dInS;
    } else {
      (dInS, sInD,) = __kyberTrade(token, srcAmount, dai);
      require(_minPrice <= sInD && dInS <= sInD);
      investment.sellPrice = sInD;
    }
  }

  /**
   * @notice Update fund statistics, and pay developer fees & commissions.
   */
  function __handleFees() internal {
    uint256 profit = 0;
    if (getBalance(dai, this) > totalFundsInDAI.add(totalCommissionLeft)) {
      profit = getBalance(dai, this).sub(totalFundsInDAI).sub(totalCommissionLeft);
    }
    totalCommissionOfCycle[cycleNumber] = commissionRate.mul(profit).add(assetFeeRate.mul(getBalance(dai, this))).div(PRECISION);
    totalCommissionLeft = totalCommissionLeft.add(totalCommissionOfCycle[cycleNumber]);
    uint256 devFee = developerFeeRate.mul(getBalance(dai, this)).div(PRECISION);
    uint256 newTotalFunds = getBalance(dai, this).sub(totalCommissionLeft).sub(devFee);

    // Update values
    emit ROI(cycleNumber, totalFundsInDAI, newTotalFunds);
    totalFundsInDAI = newTotalFunds;

    // Transfer fees
    dai.transfer(developerFeeAccount, devFee);

    // Emit event
    emit TotalCommissionPaid(cycleNumber, totalCommissionOfCycle[cycleNumber]);
  }

  /**
   * @notice Wrapper function for doing token conversion on Kyber Network
   * @param _srcToken the token to convert from
   * @param _srcAmount the amount of tokens to be converted
   * @param _destToken the destination token
   * @return _destPriceInSrc the price of the destination token, in terms of source tokens
   */
  function __kyberTrade(ERC20Detailed _srcToken, uint256 _srcAmount, ERC20Detailed _destToken)
    internal 
    returns(
      uint256 _destPriceInSrc,
      uint256 _srcPriceInDest,
      uint256 _actualDestAmount,
      uint256 _actualSrcAmount
    )
  {
    require(_srcToken != _destToken);
    uint256 beforeSrcBalance = getBalance(_srcToken, this);
    uint256 msgValue;
    uint256 rate;
    bytes memory hint;

    if (_srcToken != ETH_TOKEN_ADDRESS) {
      msgValue = 0;
      _srcToken.approve(KYBER_ADDR, 0);
      _srcToken.approve(KYBER_ADDR, _srcAmount);
    } else {
      msgValue = _srcAmount;
    }
    (,rate) = kyber.getExpectedRate(_srcToken, _destToken, _srcAmount);
    _actualDestAmount = kyber.tradeWithHint.value(msgValue)(
      _srcToken,
      _srcAmount,
      _destToken,
      this,
      MAX_QTY,
      rate,
      0,
      hint
    );
    require(_actualDestAmount > 0);
    if (_srcToken != ETH_TOKEN_ADDRESS) {
      _srcToken.approve(KYBER_ADDR, 0);
    }

    _actualSrcAmount = beforeSrcBalance.sub(getBalance(_srcToken, this));
    _destPriceInSrc = calcRateFromQty(_actualDestAmount, _actualSrcAmount, getDecimals(_destToken), getDecimals(_srcToken));
    _srcPriceInDest = calcRateFromQty(_actualSrcAmount, _actualDestAmount, getDecimals(_srcToken), getDecimals(_destToken));
  }

  function() public payable {
    if (msg.sender != KYBER_ADDR || msg.sender != previousVersion) {
      revert();
    }
  }
}