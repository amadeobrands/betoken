// Generated by CoffeeScript 2.3.2
(function() {
  var BetokenFund, BetokenLogic, BetokenProxy, BigNumber, CompoundOrderFactory, ETH_ADDR, LongCERC20Order, LongCEtherOrder, MiniMeToken, MiniMeTokenFactory, PRECISION, ShortCERC20Order, ShortCEtherOrder, ZERO_ADDR, bnToString;

  BetokenFund = artifacts.require("BetokenFund");

  BetokenProxy = artifacts.require("BetokenProxy");

  MiniMeToken = artifacts.require("MiniMeToken");

  MiniMeTokenFactory = artifacts.require("MiniMeTokenFactory");

  LongCERC20Order = artifacts.require("LongCERC20Order");

  ShortCERC20Order = artifacts.require("ShortCERC20Order");

  LongCEtherOrder = artifacts.require("LongCEtherOrder");

  ShortCEtherOrder = artifacts.require("ShortCEtherOrder");

  CompoundOrderFactory = artifacts.require("CompoundOrderFactory");

  BetokenLogic = artifacts.require("BetokenLogic");

  BigNumber = require("bignumber.js");

  ZERO_ADDR = "0x0000000000000000000000000000000000000000";

  ETH_ADDR = "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE";

  PRECISION = 1e18;

  bnToString = function(bn) {
    return BigNumber(bn).toFixed(0);
  };

  module.exports = async function() {
    var BetokenLogicContract, BetokenProxyContract, CompoundOrderFactoryContract, ControlToken, LongCERC20OrderContract, LongCEtherOrderContract, ShareToken, ShortCERC20OrderContract, ShortCEtherOrderContract, TestCERC20, TestCERC20Factory, TestCEther, TestCEtherContract, TestComptroller, TestComptrollerContract, TestDAI, TestKyberNetwork, TestKyberNetworkContract, TestPriceOracle, TestPriceOracleContract, TestToken, TestTokenFactory, accounts, betokenFund, compoundTokens, compoundTokensArray, config, controlTokenAddr, i, j, k, l, len, len1, len2, len3, m, minimeFactory, ref, ref1, ref2, shareTokenAddr, testCERC20Factory, testDAIAddr, testTokenFactory, token, tokenAddrs, tokenObj, tokenPrices, tokensInfo;
    accounts = (await web3.eth.getAccounts());
    config = require("../deployment_configs/testnet.json");
    TestToken = artifacts.require("TestToken");
    TestKyberNetwork = artifacts.require("TestKyberNetwork");
    TestTokenFactory = artifacts.require("TestTokenFactory");
    TestPriceOracle = artifacts.require("TestPriceOracle");
    TestComptroller = artifacts.require("TestComptroller");
    TestCERC20 = artifacts.require("TestCERC20");
    TestCEther = artifacts.require("TestCEther");
    TestCERC20Factory = artifacts.require("TestCERC20Factory");
    // deploy TestToken factory
    TestTokenFactory.setAsDeployed((await TestTokenFactory.new()));
    testTokenFactory = (await TestTokenFactory.deployed());
    // create TestDAI
    testDAIAddr = ((await testTokenFactory.newToken("DAI Stable Coin", "DAI", 18))).logs[0].args.addr;
    TestDAI = (await TestToken.at(testDAIAddr));
    
    // mint DAI for owner
    await TestDAI.mint(accounts[0], bnToString(1e7 * PRECISION)); // ten million
    
    // create TestTokens
    tokensInfo = require("../deployment_configs/kn_tokens.json");
    tokenAddrs = [];
    for (j = 0, len = tokensInfo.length; j < len; j++) {
      token = tokensInfo[j];
      tokenAddrs.push(((await testTokenFactory.newToken(token.name, token.symbol, token.decimals))).logs[0].args.addr);
    }
    tokenAddrs.push(TestDAI.address);
    tokenAddrs.push(ETH_ADDR);
    tokenPrices = ((function() {
      var k, ref, results;
      results = [];
      for (i = k = 1, ref = tokensInfo.length; (1 <= ref ? k <= ref : k >= ref); i = 1 <= ref ? ++k : --k) {
        results.push(bnToString(10 * PRECISION));
      }
      return results;
    })()).concat([bnToString(PRECISION), bnToString(20 * PRECISION)]);
    // deploy TestKyberNetwork
    TestKyberNetworkContract = (await TestKyberNetwork.new(tokenAddrs, tokenPrices));
    TestKyberNetwork.setAsDeployed(TestKyberNetworkContract);
    // send ETH to TestKyberNetwork
    await web3.eth.sendTransaction({
      from: accounts[0],
      to: TestKyberNetworkContract.address,
      value: 1 * PRECISION
    });
    // deploy Test Compound suite of contracts

    // deploy TestPriceOracle
    TestPriceOracleContract = (await TestPriceOracle.new(tokenAddrs, tokenPrices));
    TestPriceOracle.setAsDeployed(TestPriceOracleContract);
    // deploy TestComptroller
    TestComptrollerContract = (await TestComptroller.new());
    TestComptroller.setAsDeployed(TestComptrollerContract);
    // deploy TestCERC20Factory
    TestCERC20Factory.setAsDeployed((await TestCERC20Factory.new()));
    testCERC20Factory = (await TestCERC20Factory.deployed());
    // deploy TestCEther
    TestCEtherContract = (await TestCEther.new(TestComptrollerContract.address));
    TestCEther.setAsDeployed(TestCEtherContract);
    // send ETH to TestCEther
    await web3.eth.sendTransaction({
      from: accounts[0],
      to: TestCEtherContract.address,
      value: 1 * PRECISION
    });
    // deploy TestCERC20 contracts
    compoundTokens = {};
    ref = tokenAddrs.slice(0, +(tokenAddrs.length - 2) + 1 || 9e9);
    for (k = 0, len1 = ref.length; k < len1; k++) {
      token = ref[k];
      compoundTokens[token] = ((await testCERC20Factory.newToken(token, TestComptrollerContract.address))).logs[0].args.cToken;
    }
    ref1 = tokenAddrs.slice(0, +(tokenAddrs.length - 2) + 1 || 9e9);
    // mint tokens for KN
    for (l = 0, len2 = ref1.length; l < len2; l++) {
      token = ref1[l];
      tokenObj = (await TestToken.at(token));
      await tokenObj.mint(TestKyberNetworkContract.address, bnToString(1e12 * PRECISION)); // one trillion tokens
    }
    ref2 = tokenAddrs.slice(0, +(tokenAddrs.length - 2) + 1 || 9e9);
    
    // mint tokens for Compound markets
    for (m = 0, len3 = ref2.length; m < len3; m++) {
      token = ref2[m];
      tokenObj = (await TestToken.at(token));
      await tokenObj.mint(compoundTokens[token], bnToString(1e12 * PRECISION)); // one trillion tokens        
    }
    
    // deploy Kairo and Betoken Shares contracts
    MiniMeTokenFactory.setAsDeployed((await MiniMeTokenFactory.new()));
    minimeFactory = (await MiniMeTokenFactory.deployed());
    controlTokenAddr = ((await minimeFactory.createCloneToken(ZERO_ADDR, 0, "Kairo", 18, "KRO", false))).logs[0].args.addr;
    shareTokenAddr = ((await minimeFactory.createCloneToken(ZERO_ADDR, 0, "Betoken Shares", 18, "BTKS", true))).logs[0].args.addr;
    ControlToken = (await MiniMeToken.at(controlTokenAddr));
    ShareToken = (await MiniMeToken.at(shareTokenAddr));
    
    // deploy ShortCERC20Order
    ShortCERC20OrderContract = (await ShortCERC20Order.new());
    ShortCERC20Order.setAsDeployed(ShortCERC20OrderContract);
    await ShortCERC20OrderContract.renounceOwnership();
    // deploy ShortCEtherOrder
    ShortCEtherOrderContract = (await ShortCEtherOrder.new());
    ShortCEtherOrder.setAsDeployed(ShortCEtherOrderContract);
    await ShortCEtherOrderContract.renounceOwnership();
    // deploy LongCERC20Order
    LongCERC20OrderContract = (await LongCERC20Order.new());
    LongCERC20Order.setAsDeployed(LongCERC20OrderContract);
    await LongCERC20OrderContract.renounceOwnership();
    // deploy LongCEtherOrder
    LongCEtherOrderContract = (await LongCEtherOrder.new());
    LongCEtherOrder.setAsDeployed(LongCEtherOrderContract);
    await LongCEtherOrderContract.renounceOwnership();
    // deploy CompoundOrderFactory
    CompoundOrderFactoryContract = (await CompoundOrderFactory.new(ShortCERC20OrderContract.address, ShortCEtherOrderContract.address, LongCERC20OrderContract.address, LongCEtherOrderContract.address, TestDAI.address, TestKyberNetworkContract.address, TestComptrollerContract.address, TestPriceOracleContract.address, compoundTokens[TestDAI.address], TestCEtherContract.address));
    CompoundOrderFactory.setAsDeployed(CompoundOrderFactoryContract);
    // deploy BetokenLogic
    BetokenLogicContract = (await BetokenLogic.new());
    BetokenLogic.setAsDeployed(BetokenLogicContract);
    // deploy BetokenFund contract
    compoundTokensArray = (function() {
      var len4, n, ref3, results;
      ref3 = tokenAddrs.slice(0, +(tokenAddrs.length - 3) + 1 || 9e9);
      results = [];
      for (n = 0, len4 = ref3.length; n < len4; n++) {
        token = ref3[n];
        results.push(compoundTokens[token]);
      }
      return results;
    })();
    compoundTokensArray.push(TestCEtherContract.address);
    BetokenFund.setAsDeployed((await BetokenFund.new(ControlToken.address, ShareToken.address, accounts[0], config.phaseLengths, bnToString(config.devFundingRate), ZERO_ADDR, TestDAI.address, TestKyberNetworkContract.address, CompoundOrderFactoryContract.address, BetokenLogicContract.address)));
    betokenFund = (await BetokenFund.deployed());
    await betokenFund.initTokenListings(tokenAddrs.slice(0, +(tokenAddrs.length - 3) + 1 || 9e9).concat([ETH_ADDR]), compoundTokensArray, []);
    // deploy BetokenProxy contract
    BetokenProxyContract = (await BetokenProxy.new(betokenFund.address));
    BetokenProxy.setAsDeployed(BetokenProxyContract);
    // set proxy address in BetokenFund
    await betokenFund.setProxy(BetokenProxyContract.address);
    await ControlToken.transferOwnership(betokenFund.address);
    return (await ShareToken.transferOwnership(betokenFund.address));
  };

}).call(this);
