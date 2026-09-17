class_name OscMessage
extends RefCounted
## A minimal OSC 1.0 reader — enough for GO-style triggers. Parses a UDP
## packet into a list of `OscMessage` ({ address, args }), unwrapping
## `#bundle` containers. Arguments of type int / float / string / bool are
## decoded; anything else is skipped. No OSC sender, no address-pattern
## wildcard matching (bindings compare the address literally).

var address: String = ""
var args: Array = []


## Parse one datagram into 0+ messages.
static func parse_packet(data: PackedByteArray) -> Array:
	var out: Array = []
	_parse(data, 0, data.size(), out)
	return out


## Encode one message to an OSC packet. Args may be int, float or String.
static func encode(address: String, args: Array = []) -> PackedByteArray:
	var out := _osc_str(address)
	var tags := ","
	var body := PackedByteArray()
	for a in args:
		if a is int:
			tags += "i"
			body.append_array(_i32(int(a)))
		elif a is float:
			tags += "f"
			var b := PackedByteArray()
			b.resize(4)
			b.encode_float(0, a)
			b.reverse()
			body.append_array(b)
		else:
			tags += "s"
			body.append_array(_osc_str(String(a)))
	out.append_array(_osc_str(tags))
	out.append_array(body)
	return out


static func _osc_str(s: String) -> PackedByteArray:
	var b := s.to_utf8_buffer()
	b.append(0)
	while b.size() % 4 != 0:
		b.append(0)
	return b


static func _i32(v: int) -> PackedByteArray:
	return PackedByteArray([(v >> 24) & 255, (v >> 16) & 255, (v >> 8) & 255, v & 255])


static func _parse(data: PackedByteArray, start: int, end: int, out: Array) -> void:
	if end - start < 4 or start < 0:
		return
	var head := _read_string(data, start, end)
	if head[0] == "#bundle":
		# "#bundle\0" (8 bytes) + 8-byte time tag, then [int32 size][element]...
		var p: int = start + 16
		while p + 4 <= end:
			var sz: int = _read_i32(data, p)
			p += 4
			if sz <= 0 or p + sz > end:
				break
			_parse(data, p, p + sz, out)
			p += sz
		return

	var msg := OscMessage.new()
	msg.address = head[0]
	var p: int = head[1]
	if p < end and data[p] == 44:  # ','
		var tag_r := _read_string(data, p, end)
		var tags: String = tag_r[0]
		p = tag_r[1]
		for i in range(1, tags.length()):
			match tags[i]:
				"i", "r", "c":
					msg.args.append(_read_i32(data, p))
					p += 4
				"f":
					msg.args.append(_read_f32(data, p))
					p += 4
				"s", "S":
					var s := _read_string(data, p, end)
					msg.args.append(s[0])
					p = s[1]
				"T": msg.args.append(true)
				"F": msg.args.append(false)
				"N", "I": msg.args.append(null)
				"b", "h", "t", "d":
					# blob / 64-bit types — skip their payload so later
					# args stay aligned (blob: size + padded data; 64-bit: 8)
					if tags[i] == "b":
						var bl: int = _read_i32(data, p)
						p += 4 + _pad4(maxi(bl, 0))
					else:
						p += 8
				_:
					break
	out.append(msg)


## Read an OSC-string (null-terminated, then padded with nulls to the next
## 4-byte boundary). Returns [String, index just past the padding].
static func _read_string(data: PackedByteArray, pos: int, end: int) -> Array:
	var i := pos
	while i < end and i < data.size() and data[i] != 0:
		i += 1
	var s := data.slice(pos, i).get_string_from_utf8()
	# consumed = characters + at least one null, rounded up to a multiple of 4
	var nxt := pos + _pad4(i - pos + 1)
	return [s, nxt]


static func _read_i32(data: PackedByteArray, pos: int) -> int:
	if pos + 4 > data.size():
		return 0
	var v := (int(data[pos]) << 24) | (int(data[pos + 1]) << 16) \
		| (int(data[pos + 2]) << 8) | int(data[pos + 3])
	if v >= 0x80000000:
		v -= 0x100000000
	return v


static func _read_f32(data: PackedByteArray, pos: int) -> float:
	if pos + 4 > data.size():
		return 0.0
	var b := data.slice(pos, pos + 4)
	b.reverse()
	return b.decode_float(0)


static func _pad4(n: int) -> int:
	return (n + 3) & ~3
