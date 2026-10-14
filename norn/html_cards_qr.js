// A QR code ENCODER for the card page's QR button: the page's share link onto a phone by scanning.
//
// A line-for-line port of the bridge-bidding-system repo's `qr/qr.odin` (ISO/IEC 18004, model 2): byte mode,
// versions 1-40, error correction L/M/Q/H, Reed-Solomon over GF(256), the mask chosen by qrcodegen's penalty
// reading. It is held module for module to the same golden matrices (qrcodegen's, each scanned back by
// zxing-cpp) by that repo's `just sims test-qr-js`, so edit the two together.
//
// Written in the page script's own dialect (`var`, no arrows): the desktop engine runs it too. It is pasted
// into the footer's script where `/*{{QR_JS}}*/` stands (`render_page_epilogue`), and defines one name.
var NcQr = (function () {
	'use strict';
	var L = 0, M = 1, Q = 2, H = 3;
	var ECC_CODEWORDS_PER_BLOCK = [
		[0, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
		[0, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28],
		[0, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
		[0, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30]
	];
	var ECC_BLOCKS = [
		[0, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25],
		[0, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49],
		[0, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68],
		[0, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81]
	];
	var LEVEL_BITS = [1, 0, 3, 2];

	function rawDataModules(v) {
		var result = (16 * v + 128) * v + 64;
		if (v >= 2) {
			var aligns = Math.floor(v / 7) + 2;
			result -= (25 * aligns - 10) * aligns - 55;
			if (v >= 7) result -= 36;
		}
		return result;
	}
	function dataCodewords(v, ecc) {
		return Math.floor(rawDataModules(v) / 8) - ECC_CODEWORDS_PER_BLOCK[ecc][v] * ECC_BLOCKS[ecc][v];
	}
	function countBits(v) { return v <= 9 ? 8 : 16; }
	function dataBitsNeeded(n, v) {
		if (n >= 1 << countBits(v)) return Infinity;
		return 4 + countBits(v) + 8 * n;
	}
	function byteCapacity(v, ecc) { return Math.floor((dataCodewords(v, ecc) * 8 - 4 - countBits(v)) / 8); }

	function dataCodewordsFor(data, v, ecc) {
		var capacity = dataCodewords(v, ecc), out = new Array(capacity), n = 0, i;
		for (i = 0; i < capacity; i++) out[i] = 0;
		function write(value, count) {
			for (var b = count - 1; b >= 0; b--) {
				if ((value >> b) & 1) out[n >> 3] |= 0x80 >> (n & 7);
				n++;
			}
		}
		write(4, 4);
		write(data.length, countBits(v));
		for (i = 0; i < data.length; i++) write(data[i], 8);
		write(0, Math.min(4, capacity * 8 - n));
		n = Math.ceil(n / 8) * 8;
		for (var pad = 0xEC; n < capacity * 8; pad = pad === 0xEC ? 0x11 : 0xEC) { out[n >> 3] = pad; n += 8; }
		return out;
	}

	function gfMul(x, y) {
		var z = 0;
		for (var i = 7; i >= 0; i--) {
			z = (z << 1) ^ ((z >> 7) * 0x11D);
			z ^= ((y >> i) & 1) * x;
		}
		return z & 0xFF;
	}
	function rsDivisor(degree) {
		var result = [], root = 1, i, j;
		for (i = 0; i < degree; i++) result.push(0);
		result[degree - 1] = 1;
		for (i = 0; i < degree; i++) {
			for (j = 0; j < degree; j++) {
				result[j] = gfMul(result[j], root);
				if (j + 1 < degree) result[j] ^= result[j + 1];
			}
			root = gfMul(root, 2);
		}
		return result;
	}
	function rsRemainder(data, divisor) {
		var out = [], i;
		for (i = 0; i < divisor.length; i++) out.push(0);
		for (var k = 0; k < data.length; k++) {
			var factor = data[k] ^ out.shift();
			out.push(0);
			for (i = 0; i < out.length; i++) out[i] ^= gfMul(divisor[i], factor);
		}
		return out;
	}
	function addEccAndInterleave(data, v, ecc) {
		var blocks = ECC_BLOCKS[ecc][v], eccLen = ECC_CODEWORDS_PER_BLOCK[ecc][v];
		var raw = Math.floor(rawDataModules(v) / 8);
		var shortBlocks = blocks - raw % blocks, shortLen = Math.floor(raw / blocks);
		var divisor = rsDivisor(eccLen), result = new Array(raw), k = 0;
		for (var i = 0; i < blocks; i++) {
			var dataLen = shortLen - eccLen + (i < shortBlocks ? 0 : 1);
			var block = data.slice(k, k + dataLen), rem = rsRemainder(block, divisor), j;
			for (j = 0; j < dataLen; j++) {
				result[j === shortLen - eccLen ? j * blocks + (i - shortBlocks) : j * blocks + i] = block[j];
			}
			for (j = 0; j < eccLen; j++) result[data.length + j * blocks + i] = rem[j];
			k += dataLen;
		}
		return result;
	}

	function Matrix(size) {
		this.size = size;
		this.dark = [];
		this.fn = [];
		for (var i = 0; i < size * size; i++) { this.dark.push(false); this.fn.push(false); }
	}
	Matrix.prototype.set = function (x, y, dark) { this.dark[y * this.size + x] = dark; this.fn[y * this.size + x] = true; };

	function drawFinder(m, cx, cy) {
		for (var dy = -4; dy <= 4; dy++) {
			for (var dx = -4; dx <= 4; dx++) {
				var x = cx + dx, y = cy + dy;
				if (x >= 0 && x < m.size && y >= 0 && y < m.size) {
					var dist = Math.max(Math.abs(dx), Math.abs(dy));
					m.set(x, y, dist !== 2 && dist !== 4);
				}
			}
		}
	}
	function drawAlignment(m, cx, cy) {
		for (var dy = -2; dy <= 2; dy++) {
			for (var dx = -2; dx <= 2; dx++) m.set(cx + dx, cy + dy, Math.max(Math.abs(dx), Math.abs(dy)) !== 1);
		}
	}
	function alignmentPositions(v) {
		if (v === 1) return [];
		var n = Math.floor(v / 7) + 2;
		var step = Math.floor((v * 8 + n * 3 + 5) / (n * 4 - 4)) * 2;
		var out = [6], pos = v * 4 + 17 - 7, i;
		for (i = 1; i < n; i++) out.push(0);
		for (i = n - 1; i >= 1; i--) { out[i] = pos; pos -= step; }
		return out;
	}
	function drawFormatBits(m, ecc, mask) {
		var data = LEVEL_BITS[ecc] << 3 | mask, rem = data, i;
		for (i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >> 9) * 0x537);
		var bits = (data << 10 | rem) ^ 0x5412;
		function bit(k) { return ((bits >> k) & 1) !== 0; }
		for (i = 0; i <= 5; i++) m.set(8, i, bit(i));
		m.set(8, 7, bit(6));
		m.set(8, 8, bit(7));
		m.set(7, 8, bit(8));
		for (i = 9; i < 15; i++) m.set(14 - i, 8, bit(i));
		for (i = 0; i < 8; i++) m.set(m.size - 1 - i, 8, bit(i));
		for (i = 8; i < 15; i++) m.set(8, m.size - 15 + i, bit(i));
		m.set(8, m.size - 8, true);
	}
	function drawVersionBits(m, v) {
		if (v < 7) return;
		var rem = v, i;
		for (i = 0; i < 12; i++) rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
		var bits = v << 12 | rem;
		for (i = 0; i < 18; i++) {
			var dark = ((bits >> i) & 1) !== 0, a = m.size - 11 + i % 3, b = Math.floor(i / 3);
			m.set(a, b, dark);
			m.set(b, a, dark);
		}
	}
	function drawFunctionPatterns(m, v) {
		for (var i = 0; i < m.size; i++) { m.set(6, i, i % 2 === 0); m.set(i, 6, i % 2 === 0); }
		drawFinder(m, 3, 3);
		drawFinder(m, m.size - 4, 3);
		drawFinder(m, 3, m.size - 4);
		var pos = alignmentPositions(v), n = pos.length;
		for (var a = 0; a < n; a++) {
			for (var b = 0; b < n; b++) {
				var corner = (a === 0 && b === 0) || (a === 0 && b === n - 1) || (a === n - 1 && b === 0);
				if (!corner) drawAlignment(m, pos[a], pos[b]);
			}
		}
		drawFormatBits(m, L, 0);
		drawVersionBits(m, v);
	}
	function drawCodewords(m, codewords) {
		var i = 0, total = codewords.length * 8;
		for (var right = m.size - 1; right >= 1; right -= 2) {
			if (right === 6) right = 5;
			var upward = ((right + 1) & 2) === 0;
			for (var vert = 0; vert < m.size; vert++) {
				var y = upward ? m.size - 1 - vert : vert;
				for (var j = 0; j < 2; j++) {
					var x = right - j, at = y * m.size + x;
					if (!m.fn[at] && i < total) {
						m.dark[at] = ((codewords[i >> 3] >> (7 - (i & 7))) & 1) !== 0;
						i++;
					}
				}
			}
		}
	}
	function applyMask(m, mask) {
		for (var y = 0; y < m.size; y++) {
			for (var x = 0; x < m.size; x++) {
				var invert;
				switch (mask) {
				case 0: invert = (x + y) % 2 === 0; break;
				case 1: invert = y % 2 === 0; break;
				case 2: invert = x % 3 === 0; break;
				case 3: invert = (x + y) % 3 === 0; break;
				case 4: invert = (Math.floor(x / 3) + Math.floor(y / 2)) % 2 === 0; break;
				case 5: invert = x * y % 2 + x * y % 3 === 0; break;
				case 6: invert = (x * y % 2 + x * y % 3) % 2 === 0; break;
				default: invert = ((x + y) % 2 + x * y % 3) % 2 === 0;
				}
				var at = y * m.size + x;
				if (invert && !m.fn[at]) m.dark[at] = !m.dark[at];
			}
		}
	}

	// The standard's mask evaluation, in qrcodegen's run-length reading of N3 (see qr.odin's `penalty`).
	function penalty(m) {
		var n = m.size, score = 0, a, b, h;
		function addRun(history, length) {
			if (history[0] === 0) length += n;
			for (var k = 6; k >= 1; k--) history[k] = history[k - 1];
			history[0] = length;
		}
		function finderLike(h) {
			var u = h[1], core = u > 0 && h[2] === u && h[3] === u * 3 && h[4] === u && h[5] === u;
			return (core && h[0] >= u * 4 && h[6] >= u ? 1 : 0) + (core && h[6] >= u * 4 && h[0] >= u ? 1 : 0);
		}
		for (h = 0; h < 2; h++) {
			for (a = 0; a < n; a++) {
				var colour = false, run = 0, history = [0, 0, 0, 0, 0, 0, 0];
				for (b = 0; b < n; b++) {
					var cell = h === 0 ? m.dark[a * n + b] : m.dark[b * n + a];
					if (cell === colour) {
						run++;
						if (run === 5) score += 3; else if (run > 5) score += 1;
					} else {
						addRun(history, run);
						if (!colour) score += finderLike(history) * 40;
						colour = !colour;
						run = 1;
					}
				}
				if (colour) { addRun(history, run); run = 0; }
				addRun(history, run + n);
				score += finderLike(history) * 40;
			}
		}
		for (var y = 0; y < n - 1; y++) {
			for (var x = 0; x < n - 1; x++) {
				var d = m.dark[y * n + x];
				if (d === m.dark[y * n + x + 1] && d === m.dark[(y + 1) * n + x] && d === m.dark[(y + 1) * n + x + 1]) score += 3;
			}
		}
		var dark = 0, total = n * n;
		for (var i = 0; i < total; i++) if (m.dark[i]) dark++;
		score += (Math.floor((Math.abs(dark * 20 - total * 10) + total - 1) / total) - 1) * 10;
		return score;
	}

	// `text` as UTF-8 bytes (a share link is ASCII; a title in it is not).
	function utf8(text) {
		var out = [];
		for (var i = 0; i < text.length; i++) {
			var cp = text.charCodeAt(i);
			if (cp >= 0xD800 && cp < 0xDC00 && i + 1 < text.length) cp = 0x10000 + ((cp - 0xD800) << 10) + (text.charCodeAt(++i) - 0xDC00);
			if (cp < 0x80) out.push(cp);
			else if (cp < 0x800) out.push(0xC0 | cp >> 6, 0x80 | cp & 63);
			else if (cp < 0x10000) out.push(0xE0 | cp >> 12, 0x80 | cp >> 6 & 63, 0x80 | cp & 63);
			else out.push(0xF0 | cp >> 18, 0x80 | cp >> 12 & 63, 0x80 | cp >> 6 & 63, 0x80 | cp & 63);
		}
		return out;
	}

	// The code for `text` at the smallest version that holds it, or null when none in range does.
	// options: ecc ('L'|'M'|'Q'|'H', the least acceptable; default 'M'), boostEcc (default true: raised while the
	// data still fits the version), minVersion / maxVersion (default 1 / 40), mask (-1 or absent: by penalty).
	// Returns {version, size, ecc ('L'..'H'), mask, dark: [bool], row-major, no quiet zone}.
	function encode(text, options) {
		options = options || {};
		var data = typeof text === 'string' ? utf8(text) : text;
		var ecc = 'LMQH'.indexOf(options.ecc || 'M');
		var minV = options.minVersion || 1, maxV = options.maxVersion || 40;
		var mask = options.mask === undefined ? -1 : options.mask;
		var v = 0, e;
		for (var c = minV; c <= maxV; c++) {
			if (dataBitsNeeded(data.length, c) <= dataCodewords(c, ecc) * 8) { v = c; break; }
		}
		if (!v) return null;
		if (options.boostEcc !== false) {
			for (e = ecc + 1; e <= H; e++) if (dataBitsNeeded(data.length, v) <= dataCodewords(v, e) * 8) ecc = e;
		}
		var codewords = addEccAndInterleave(dataCodewordsFor(data, v, ecc), v, ecc);
		var m = new Matrix(v * 4 + 17);
		drawFunctionPatterns(m, v);
		drawCodewords(m, codewords);
		if (mask < 0) {
			var best = Infinity;
			for (var cand = 0; cand < 8; cand++) {
				applyMask(m, cand);
				drawFormatBits(m, ecc, cand);
				var score = penalty(m);
				if (score < best) { best = score; mask = cand; }
				applyMask(m, cand);
			}
		}
		applyMask(m, mask);
		drawFormatBits(m, ecc, mask);
		return { version: v, size: m.size, ecc: 'LMQH'.charAt(ecc), mask: mask, dark: m.dark };
	}

	// The code as one SVG (a light ground, the dark modules as one path of horizontal runs), as qr.odin's `svg`.
	function svg(code, border) {
		if (border === undefined) border = 4;
		var side = code.size + 2 * border, d = [];
		for (var y = 0; y < code.size; y++) {
			for (var x = 0; x < code.size;) {
				if (!code.dark[y * code.size + x]) { x++; continue; }
				var run = 1;
				while (x + run < code.size && code.dark[y * code.size + x + run]) run++;
				d.push('M' + (x + border) + ' ' + (y + border) + 'h' + run + 'v1h-' + run + 'z');
				x += run;
			}
		}
		return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ' + side + ' ' + side +
			'" shape-rendering="crispEdges"><rect width="100%" height="100%" fill="#fff"/><path fill="#000" d="' +
			d.join('') + '"/></svg>';
	}

	return { encode: encode, svg: svg, byteCapacity: function (v, ecc) { return byteCapacity(v, 'LMQH'.indexOf(ecc)); } };
})();
