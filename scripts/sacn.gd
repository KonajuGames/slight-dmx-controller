class_name Sacn
extends RefCounted
## E1.31 (streaming ACN) — DMX over Ethernet, the ANSI-standard cousin of
## Art-Net. Multicast by default (239.255.<hi>.<lo>, UDP 5568); a receiver
## just subscribes to the universe's group. This builds one E1.31 *Data*
## packet (0x00 start code + 512 slots).

const PORT := 5568
const _ACN_PID := "ASC-E1.17"           # 12-byte packet identifier (padded)
const VECTOR_ROOT_DATA := 0x00000004
const VECTOR_FRAMING_DATA := 0x00000002
const VECTOR_DMP_SET_PROPERTY := 0x02


## The multicast group for a universe: 239.255.(universe >> 8).(universe & 255).
static func multicast_ip(universe: int) -> String:
	return "239.255.%d.%d" % [(universe >> 8) & 0xFF, universe & 0xFF]


## A random 16-byte CID (UUID v4). Persist it so a receiver sees one
## stable source across restarts instead of a new one each launch.
static func random_cid() -> PackedByteArray:
	var b := Crypto.new().generate_random_bytes(16)
	b[6] = (b[6] & 0x0F) | 0x40
	b[8] = (b[8] & 0x3F) | 0x80
	return b


## One E1.31 Data packet. `dmx` is the 512 slot values (start code is added
## here). `sequence` wraps 0..255, bumped once per packet per universe.
static func data_packet(universe: int, dmx: PackedByteArray, cid: PackedByteArray,
		source_name: String, priority: int, sequence: int) -> PackedByteArray:
	const SLOTS := 512
	var total := 126 + SLOTS                 # 638 for a full universe
	var p := PackedByteArray()
	p.resize(total)                          # zero-filled

	# --- Root layer (0..37) ---
	_u16(p, 0, 0x0010)                       # preamble size
	_u16(p, 2, 0x0000)                       # post-amble size
	var pid := _ACN_PID.to_ascii_buffer()
	for i in range(pid.size()):
		p[4 + i] = pid[i]                    # 4..15 (rest already 0)
	_flags_len(p, 16, total - 16)
	_u32(p, 18, VECTOR_ROOT_DATA)
	for i in range(16):
		p[22 + i] = cid[i] if i < cid.size() else 0

	# --- Framing layer (38..114) ---
	_flags_len(p, 38, total - 38)
	_u32(p, 40, VECTOR_FRAMING_DATA)
	var nm := source_name.to_utf8_buffer()
	for i in range(mini(nm.size(), 63)):
		p[44 + i] = nm[i]                    # 44..107, 64 bytes, null-padded
	p[108] = clampi(priority, 0, 200)
	_u16(p, 109, 0)                          # synchronization address
	p[111] = sequence & 0xFF
	p[112] = 0                               # options
	_u16(p, 113, universe)

	# --- DMP layer (115..637) ---
	_flags_len(p, 115, total - 115)
	p[117] = VECTOR_DMP_SET_PROPERTY
	p[118] = 0xA1                            # address & data type
	_u16(p, 119, 0x0000)                     # first property address
	_u16(p, 121, 0x0001)                     # address increment
	_u16(p, 123, SLOTS + 1)                  # property value count (start code + slots)
	p[125] = 0x00                            # DMX start code
	for i in range(SLOTS):
		p[126 + i] = dmx[i] if i < dmx.size() else 0

	return p


static func _u16(p: PackedByteArray, off: int, v: int) -> void:
	p[off] = (v >> 8) & 0xFF
	p[off + 1] = v & 0xFF


static func _u32(p: PackedByteArray, off: int, v: int) -> void:
	p[off] = (v >> 24) & 0xFF
	p[off + 1] = (v >> 16) & 0xFF
	p[off + 2] = (v >> 8) & 0xFF
	p[off + 3] = v & 0xFF


## PDU "flags and length": top nibble 0x7, then a 12-bit length counting
## from this field to the end of the packet.
static func _flags_len(p: PackedByteArray, off: int, length: int) -> void:
	p[off] = 0x70 | ((length >> 8) & 0x0F)
	p[off + 1] = length & 0xFF
