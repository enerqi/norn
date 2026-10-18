#+build !js
package norn

import "core:testing"

@(test)
test_contract_score_makes :: proc(t: ^testing.T) {
	c :: proc(level: int, strain: Contract_Strain, doubling := Doubling.None) -> Contract {
		return {level = level, strain = strain, declarer = .South, doubling = doubling}
	}
	testing.expect_value(t, contract_score(c(2, .Diamonds), 8, false), 90)
	testing.expect_value(t, contract_score(c(1, .NoTrumps), 9, false), 150)
	testing.expect_value(t, contract_score(c(3, .NoTrumps), 9, false), 400)
	testing.expect_value(t, contract_score(c(3, .NoTrumps), 10, true), 630)
	testing.expect_value(t, contract_score(c(4, .Spades), 10, true), 620)
	testing.expect_value(t, contract_score(c(5, .Clubs), 11, false), 400)
	testing.expect_value(t, contract_score(c(6, .Hearts), 12, false), 980)
	testing.expect_value(t, contract_score(c(6, .NoTrumps), 12, true), 1440)
	testing.expect_value(t, contract_score(c(7, .Spades), 13, true), 2210)
	// Doubled into game, with the insult and doubled overtricks.
	testing.expect_value(t, contract_score(c(2, .Hearts, .Doubled), 8, false), 470)
	testing.expect_value(t, contract_score(c(2, .Hearts, .Doubled), 9, true), 870)
	testing.expect_value(t, contract_score(c(1, .NoTrumps, .Redoubled), 7, false), 560)
	// Doubled but not into game: 1C doubled is 40, a partscore.
	testing.expect_value(t, contract_score(c(1, .Clubs, .Doubled), 7, false), 140)
}

@(test)
test_contract_score_down :: proc(t: ^testing.T) {
	c :: proc(doubling := Doubling.None) -> Contract {
		return {level = 4, strain = .Spades, declarer = .North, doubling = doubling}
	}
	testing.expect_value(t, contract_score(c(), 8, false), -100)
	testing.expect_value(t, contract_score(c(), 8, true), -200)
	testing.expect_value(t, contract_score(c(.Doubled), 9, false), -100)
	testing.expect_value(t, contract_score(c(.Doubled), 7, false), -500)
	testing.expect_value(t, contract_score(c(.Doubled), 6, false), -800)
	testing.expect_value(t, contract_score(c(.Doubled), 8, true), -500)
	testing.expect_value(t, contract_score(c(.Doubled), 7, true), -800)
	testing.expect_value(t, contract_score(c(.Redoubled), 8, false), -600)
}

@(test)
test_imps :: proc(t: ^testing.T) {
	testing.expect_value(t, imps(0), 0)
	testing.expect_value(t, imps(10), 0)
	testing.expect_value(t, imps(20), 1)
	testing.expect_value(t, imps(-30), -1)
	testing.expect_value(t, imps(420), 9)
	testing.expect_value(t, imps(430), 10)
	testing.expect_value(t, imps(-620), -12)
	testing.expect_value(t, imps(1430), 16)
	testing.expect_value(t, imps(5000), 24)
}

@(test)
test_auction_doubling :: proc(t: ^testing.T) {
	contract, ok := derive_contract(.North, {"1S", "p", "4S", "d", "p", "p", "p"})
	testing.expect(t, ok)
	testing.expect_value(t, contract.doubling, Doubling.Doubled)
	contract, ok = derive_contract(.North, {"1S", "d", "r", "p", "p", "p"})
	testing.expect_value(t, contract.doubling, Doubling.Redoubled)
	// A bid after the double takes it away.
	contract, ok = derive_contract(.North, {"1S", "d", "2S", "p", "p", "p"})
	testing.expect_value(t, contract.doubling, Doubling.None)
	testing.expect_value(t, contract.level, 2)
}
