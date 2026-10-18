package norn

/*
	score.odin — duplicate scoring and the IMP scale.

	What a contract scores for the tricks its side took, and how many IMPs a difference in points is worth.
	Both are the laws' tables (duplicate bridge, Law 77 and the IMP scale), so they live with the contract
	model rather than with any one report. Points are always the DECLARING side's: positive when the contract
	makes, negative when it goes down.
*/

// The declaring side's duplicate score for `contract` when that side takes `tricks` tricks (0..13), at
// `vulnerable` (the declaring side's vulnerability).
contract_score :: proc "contextless" (contract: Contract, tricks: int, vulnerable: bool) -> int {
	needed := contract.level + 6
	factor := 1 << uint(contract.doubling) // 1, 2 or 4
	if tricks < needed {
		return -undertrick_penalty(needed - tricks, contract.doubling, vulnerable)
	}
	// The tricks bid, which decide game; the overtricks score apart from them.
	bid_points := trick_points(contract.strain, contract.level) * factor
	score := bid_points
	if bid_points >= 100 {
		score += 500 if vulnerable else 300
	} else {
		score += 50
	}
	switch contract.level {
	case 6:
		score += 750 if vulnerable else 500
	case 7:
		score += 1500 if vulnerable else 1000
	}
	over := tricks - needed
	switch contract.doubling {
	case .None:
		score += over * (30 if contract.strain == .NoTrumps else trick_points(contract.strain, 1))
	case .Doubled:
		score += 50 + over * (200 if vulnerable else 100)
	case .Redoubled:
		score += 100 + over * (400 if vulnerable else 200)
	}
	return score
}

// Points for the first `level` tricks over book in `strain`, undoubled: 20 a minor trick, 30 a major one,
// notrumps 40 for the first and 30 after.
@(private = "file")
trick_points :: proc "contextless" (strain: Contract_Strain, level: int) -> int {
	switch strain {
	case .Clubs, .Diamonds:
		return 20 * level
	case .Hearts, .Spades:
		return 30 * level
	case .NoTrumps:
		return 40 + 30 * (level - 1)
	}
	return 0
}

// The defenders' points for `down` undertricks. Undoubled: 50 a trick, 100 vulnerable. Doubled, not
// vulnerable: 100, then 200 each for the second and third, 300 each after; vulnerable: 200, then 300 each.
// Redoubled is twice doubled.
@(private = "file")
undertrick_penalty :: proc "contextless" (down: int, doubling: Doubling, vulnerable: bool) -> int {
	if doubling == .None {
		return down * (100 if vulnerable else 50)
	}
	penalty := 0
	for i in 1 ..= down {
		switch {
		case vulnerable:
			penalty += 200 if i == 1 else 300
		case i == 1:
			penalty += 100
		case i <= 3:
			penalty += 200
		case:
			penalty += 300
		}
	}
	return penalty * (2 if doubling == .Redoubled else 1)
}

// The IMPs a difference of `points` is worth, with its sign.
imps :: proc "contextless" (points: int) -> int {
	// The smallest difference that scores each IMP: 20-40 points is 1 IMP, ... 4000 and up is 24.
	THRESHOLDS :: [24]int {
		20, 50, 90, 130, 170, 220, 270, 320, 370, 430, 500, 600,
		750, 900, 1100, 1300, 1500, 1750, 2000, 2250, 2500, 3000, 3500, 4000,
	}
	thresholds := THRESHOLDS
	size := abs(points)
	n := 0
	for t in thresholds {
		if size < t {
			break
		}
		n += 1
	}
	return n if points >= 0 else -n
}
