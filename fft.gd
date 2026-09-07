class_name FFT
extends RefCounted
## In-place iterative radix-2 Cooley–Tukey FFT for power-of-two sizes.
## Used by SongAnalyzer for the STFT (chroma / timbre / onset features).

## Hann-windowed magnitude spectrum of `n` real samples starting at
## `offset`. Returns n/2 + 1 bins (DC … Nyquist).
static func magnitude(samples: PackedFloat32Array, offset: int, n: int) -> PackedFloat32Array:
	var re := PackedFloat32Array()
	var im := PackedFloat32Array()
	re.resize(n)
	im.resize(n)
	var inv := 1.0 / float(n - 1)
	for i in range(n):
		var idx := offset + i
		var s: float = samples[idx] if idx >= 0 and idx < samples.size() else 0.0
		re[i] = s * (0.5 - 0.5 * cos(TAU * i * inv))   # Hann window
		im[i] = 0.0
	_transform(re, im, n)
	var half := n / 2 + 1
	var out := PackedFloat32Array()
	out.resize(half)
	for i in range(half):
		out[i] = sqrt(re[i] * re[i] + im[i] * im[i])
	return out


static func _transform(re: PackedFloat32Array, im: PackedFloat32Array, n: int) -> void:
	# bit-reversal permutation
	var j := 0
	for i in range(1, n):
		var bit := n >> 1
		while j & bit:
			j ^= bit
			bit >>= 1
		j ^= bit
		if i < j:
			var t := re[i]; re[i] = re[j]; re[j] = t
			t = im[i]; im[i] = im[j]; im[j] = t

	var seg := 2
	while seg <= n:
		var ang := -TAU / seg
		var wr := cos(ang)
		var wi := sin(ang)
		var i := 0
		while i < n:
			var cr := 1.0
			var ci := 0.0
			var half := seg >> 1
			for k in range(half):
				var a := i + k
				var b := a + half
				var tr := cr * re[b] - ci * im[b]
				var ti := cr * im[b] + ci * re[b]
				re[b] = re[a] - tr
				im[b] = im[a] - ti
				re[a] += tr
				im[a] += ti
				var ncr := cr * wr - ci * wi
				ci = cr * wi + ci * wr
				cr = ncr
			i += seg
		seg <<= 1
