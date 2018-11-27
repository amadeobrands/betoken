// Generated by CoffeeScript 2.3.2
(function() {
  var KAIRO_ADDR, Kairo, MiniMeToken, inactive_managers;

  MiniMeToken = artifacts.require("MiniMeToken");

  inactive_managers = require("./inactive_managers.json");

  KAIRO_ADDR = "0xDeB05FE4905EE7662b1230e7c1f29F386E598E66";

  Kairo = MiniMeToken.at(KAIRO_ADDR);

  module.exports = async function(callback) {
    var i, j, len, manager;
    i = 1;
    for (j = 0, len = inactive_managers.length; j < len; j++) {
      manager = inactive_managers[j];
      console.log(manager.address + ` deleting... ${i}/${inactive_managers.length}`);
      i += 1;
      await Kairo.balanceOf.call(manager.address).then(function(balance) {
        return Kairo.destroyTokens(manager.address, balance);
      });
    }
  };

}).call(this);
