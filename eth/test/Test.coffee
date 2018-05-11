BetokenFund = artifacts.require "BetokenFund"
ControlToken = artifacts.require "ControlToken"
ShareToken = artifacts.require "ShareToken"
TestKyberNetwork = artifacts.require "TestKyberNetwork"
TestToken = artifacts.require "TestToken"
TestTokenFactory = artifacts.require "TestTokenFactory"

ETH_TOKEN_ADDRESS = "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
epsilon = 1e-5

etherPrice = 600
tokenPrice = 1000
etherPrecision = 1e18
tokenPrecision = 1e11
exitFee = 0.03

FUND = (cycle, phase, account) ->
  fund = await BetokenFund.deployed()
  if cycle-1 > 0
    for i in [1..cycle-1]
      for j in [0..2]
        await fund.nextPhase({from: account})
  if phase >= 0
    for i in [0..phase]
      await fund.nextPhase({from: account})
  return fund

DAI = (fund) ->
  daiAddr = await fund.daiAddr.call()
  return TestToken.at(daiAddr)

KN = (fund) ->
  kyberAddr = await fund.kyberAddr.call()
  return TestKyberNetwork.at(kyberAddr)

TK = (symbol) ->
  factory = await TestTokenFactory.deployed()
  addr = await factory.getToken.call(symbol)
  return TestToken.at(addr)

ST = () -> await ShareToken.deployed()

XR = () -> await ControlToken.deployed()

contract("first_cycle", (accounts) ->
  owner = accounts[0]
  account = accounts[1]

  it("start_cycle", () ->
    fund = await FUND(1, -1, owner)

    # start cycle
    await fund.nextPhase({from: owner})

    # check phase
    cyclePhase = +await fund.cyclePhase.call()
    assert.equal(cyclePhase, 0, "cycle phase didn't change after cycle start")

    # check cycle number
    cycleNumber = +await fund.cycleNumber.call()
    assert.equal(cycleNumber, 1, "cycle number didn't change after cycle start")
  )

  it("deposit_ether", () ->
    fund = await BetokenFund.deployed()
    st = await ST()

    # deposit ether
    amount = etherPrecision
    prevEtherBlnce = await web3.eth.getBalance(account)
    await fund.deposit({from: account, value: amount, gasPrice: 0})

    # check shares
    shareBlnce = await st.balanceOf.call(account)
    assert.equal(shareBlnce.toNumber(), amount * etherPrice, "received share amount incorrect")

    # check fund balance
    fundBalance = await fund.totalFundsInDAI.call()
    assert.equal(fundBalance.toNumber(), amount * etherPrice, "fund balance incorrect")

    # check user ether balance
    etherBlnce = await web3.eth.getBalance(account)
    assert.equal(prevEtherBlnce.sub(etherBlnce).toNumber(), amount, "ether balance increase incorrect")
  )

  it("deposit_dai", () ->
    fund = await BetokenFund.deployed()
    dai = await DAI(fund)
    st = await ST()
    account2 = accounts[2]

    # mint DAI for user
    amount = 1 * etherPrecision
    await dai.mint(account2, amount, {from: owner})

    # deposit DAI
    fundBalance = await fund.totalFundsInDAI.call()
    prevDAIBlnce = await dai.balanceOf.call(account2)
    prevShareBlnce = await st.balanceOf.call(account2)
    await dai.approve(fund.address, amount, {from: account2})
    await fund.depositToken(dai.address, amount, {from: account2})
    await dai.approve(fund.address, 0, {from: account2})

    # check shares
    shareBlnce = await st.balanceOf.call(account2)
    assert.equal(shareBlnce.sub(prevShareBlnce).toNumber(), amount, "received share amount incorrect")

    # check fund balance
    newFundBalance = await fund.totalFundsInDAI.call()
    assert.equal(newFundBalance.sub(fundBalance).toNumber(), amount, "fund balance increase incorrect")

    # check dai balance
    daiBlnce = await await dai.balanceOf.call(account2)
    assert.equal(prevDAIBlnce.sub(daiBlnce).toNumber(), amount, "DAI balance decrease incorrect")
  )

  it("deposit_token", () ->
    fund = await BetokenFund.deployed()
    token = await TK("AST")
    st = await ST()

    # mint token for user
    amount = 1000 * tokenPrecision
    await token.mint(account, amount, {from: owner})

    # deposit token
    fundBalance = await fund.totalFundsInDAI.call()
    prevTokenBlnce = await token.balanceOf.call(account)
    prevShareBlnce = await st.balanceOf.call(account)
    await token.approve(fund.address, amount, {from: account})
    await fund.depositToken(token.address, amount, {from: account})
    await token.approve(fund.address, 0, {from: account})

    # check shares
    shareBlnce = await st.balanceOf.call(account)
    assert.equal(shareBlnce.sub(prevShareBlnce).toNumber(), Math.round(amount * tokenPrice * etherPrecision / tokenPrecision), "received share amount incorrect")

    # check fund balance
    newFundBalance = await fund.totalFundsInDAI.call()
    assert.equal(newFundBalance.sub(fundBalance).toNumber(), Math.round(amount * tokenPrice * etherPrecision / tokenPrecision), "fund balance increase incorrect")

    # check token balance
    tokenBlnce = await await token.balanceOf.call(account)
    assert.equal(prevTokenBlnce.sub(tokenBlnce).toNumber(), amount, "token balance decrease incorrect")
  )

  it("withdraw_ether", () ->
    fund = await BetokenFund.deployed()
    st = await ST()

    # withdraw ether
    amount = 0.1 * etherPrecision
    prevShareBlnce = await st.balanceOf.call(account)
    prevFundBlnce = await fund.totalFundsInDAI.call()
    prevEtherBlnce = await web3.eth.getBalance(account)
    await fund.withdraw(amount, {from: account, gasPrice: 0})

    # check shares
    shareBlnce = await st.balanceOf.call(account)
    assert.equal(prevShareBlnce.sub(shareBlnce).toNumber(), amount, "burnt share amount incorrect")

    # check fund balance
    fundBlnce = await fund.totalFundsInDAI.call()
    assert.equal(prevFundBlnce.sub(fundBlnce).toNumber(), amount, "fund balance decrease incorrect")

    # check ether balance
    etherBlnce = await web3.eth.getBalance(account)
    assert.equal(etherBlnce.sub(prevEtherBlnce).toNumber(), Math.round(amount * (1 - exitFee) / etherPrice), "ether balance increase incorrect")
  )

  it("withdraw_dai", () ->
    fund = await BetokenFund.deployed()
    dai = await DAI(fund)
    st = await ST()

    # withdraw dai
    amount = 0.1 * etherPrecision
    prevShareBlnce = await st.balanceOf.call(account)
    prevFundBlnce = await fund.totalFundsInDAI.call()
    prevDAIBlnce = await dai.balanceOf.call(account)
    await fund.withdrawToken(dai.address, amount, {from: account})

    # check shares
    shareBlnce = await st.balanceOf.call(account)
    assert.equal(prevShareBlnce.sub(shareBlnce).toNumber(), amount, "burnt share amount incorrect")

    # check fund balance
    fundBlnce = await fund.totalFundsInDAI.call()
    assert.equal(prevFundBlnce.sub(fundBlnce).toNumber(), amount, "fund balance decrease incorrect")

    # check dai balance
    daiBlnce = await await dai.balanceOf.call(account)
    assert.equal(daiBlnce.sub(prevDAIBlnce).toNumber(), amount * (1 - exitFee), "DAI balance increase incorrect")
  )

  it("withdraw_token", () ->
    fund = await BetokenFund.deployed()
    token = await TK("AST")
    st = await ST()

    # withdraw token
    amount = 1 * etherPrecision

    prevShareBlnce = await st.balanceOf.call(account)
    prevFundBlnce = await fund.totalFundsInDAI.call()
    prevTokenBlnce = await token.balanceOf.call(account)
    await fund.withdrawToken(token.address, amount, {from: account})

    # check shares
    shareBlnce = await st.balanceOf.call(account)
    assert.equal(prevShareBlnce.sub(shareBlnce).toNumber(), amount, "burnt share amount incorrect")

    # check fund balance
    fundBlnce = await fund.totalFundsInDAI.call()
    assert.equal(prevFundBlnce.sub(fundBlnce).toNumber(), amount, "fund balance decrease incorrect")

    # check token balance
    tokenBlnce = await await token.balanceOf.call(account)
    assert.equal(tokenBlnce.sub(prevTokenBlnce).toNumber(), Math.round(amount * (1 - exitFee) * tokenPrecision / etherPrecision / tokenPrice), "DAI balance increase incorrect")
  )

  it("phase_0_to_1", () ->
    fund = await BetokenFund.deployed()
    await fund.nextPhase({from: owner})
  )

  it("buy_ether_and_sell", () ->
    fund = await BetokenFund.deployed()
    xr = await XR()

    prevKROBlnce = await xr.balanceOf.call(account)
    prevFundEtherBlnce = await web3.eth.getBalance(fund.address)

    # buy ether
    amount = 0.01 * etherPrecision
    kroBlnce = await xr.balanceOf.call(account)
    await fund.createInvestment(ETH_TOKEN_ADDRESS, amount, {from: account, gasPrice: 0})

    # check KRO balance
    kroBlnce = await xr.balanceOf.call(account)
    assert.equal(prevKROBlnce.sub(kroBlnce).toNumber(), amount, "Kairo balance decrease incorrect")

    # check fund ether balance
    fundDAIBlnce = await fund.totalFundsInDAI.call()
    kroTotalSupply = await xr.totalSupply.call()
    fundEtherBlnce = await web3.eth.getBalance(fund.address)
    assert.equal(fundEtherBlnce.sub(prevFundEtherBlnce).toNumber(), Math.floor(fundDAIBlnce.div(kroTotalSupply).mul(amount).div(etherPrice).toNumber()), "ether balance increase incorrect")

    # sell ether
    await fund.sellInvestmentAsset(0, {from: account, gasPrice: 0})

    # check KRO balance
    kroBlnce = await xr.balanceOf.call(account)
    #assert.equal(prevKROBlnce.sub(kroBlnce).toNumber() < epsilon, true, "Kairo balance changed")

    # check fund ether balance
    fundEtherBlnce = await web3.eth.getBalance(fund.address)
    assert.equal(fundEtherBlnce.toNumber(), prevFundEtherBlnce.toNumber(), "fund ether balance changed")
  )

  it("buy_token_and_sell", () ->
    fund = await BetokenFund.deployed()
    xr = await XR()
    token = await TK("AST")

    prevKROBlnce = await xr.balanceOf.call(account)
    prevFundTokenBlnce = await token.balanceOf(fund.address)

    # buy token
    amount = 100 * etherPrecision
    await fund.createInvestment(token.address, amount, {from: account, gasPrice: 0})

    # check KRO balance
    kroBlnce = await xr.balanceOf.call(account)
    assert.equal(prevKROBlnce.sub(kroBlnce).toNumber(), amount, "Kairo balance decrease incorrect")

    # check fund token balance
    fundDAIBlnce = await fund.totalFundsInDAI.call()
    kroTotalSupply = await xr.totalSupply.call()
    fundTokenBlnce = await token.balanceOf(fund.address)
    assert.equal(fundTokenBlnce.sub(prevFundTokenBlnce).toNumber(), Math.floor(fundDAIBlnce.mul(tokenPrecision).div(kroTotalSupply).mul(amount).div(tokenPrice).div(etherPrecision).toNumber()), "token balance increase incorrect")

    # sell token
    await fund.sellInvestmentAsset(1, {from: account, gasPrice: 0})

    # check KRO balance
    kroBlnce = await xr.balanceOf.call(account)
    assert.equal(prevKROBlnce.sub(kroBlnce).div(prevKROBlnce).toNumber() < epsilon, true, "Kairo balance changed")

    # check fund token balance
    fundTokenBlnce = await token.balanceOf(fund.address)
    assert.equal(fundTokenBlnce.toNumber(), prevFundTokenBlnce.toNumber(), "fund token balance changed")
  )

  it("phase_1_to_2", () ->
    fund = await BetokenFund.deployed()
    await fund.nextPhase({from: owner})
  )

  it("redeem_commission", () ->
    fund = await BetokenFund.deployed()
    dai = await DAI(fund)

    prevDAIBlnce = await dai.balanceOf.call(account)

    # redeem commission
    await fund.redeemCommission({from: account})

    # check DAI balance
    daiBlnce = await dai.balanceOf.call(account)
    assert.equal(daiBlnce.sub(prevDAIBlnce).toNumber() > 0, true, "didn't receive commission")
    # TODO: actually check the amount
  )

  it("redeem_commission_in_shares", () ->
    fund = await BetokenFund.deployed()
    st = await ST()
    account2 = accounts[2]

    prevShareBlnce = await st.balanceOf.call(account2)

    # redeem commission
    await fund.redeemCommissionInShares({from: account2})

    # check Share balance
    shareBlnce = await st.balanceOf.call(account2)
    assert.equal(shareBlnce.sub(prevShareBlnce).toNumber() > 0, true, "didn't receive commission")
    # TODO: actually check the amount
  )

  it("next_cycle", () ->
    fund = await BetokenFund.deployed()
    await fund.nextPhase({from: owner})
  )
)