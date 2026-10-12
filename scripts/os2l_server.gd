class_name Os2lServer
extends Node
## An OS2L (Open Sound to Light) server: the lighting end of the link
## that DJ software — VirtualDJ in particular — connects *to*.
##
## OS2L is JSON objects over TCP, back to back with no delimiter. The DJ
## software sends `beat` (every beat: position, BPM, strength), `btn`
## (a skin / controller button mapped to the lighting software) and `cmd`
## (a numbered command with a value). The server can send `feedback`
## back (to light a DJ-side button).
##
## VirtualDJ also lets the server `subscribe` to VDJscript queries
## ("deck 1 get_bpm", "deck 2 get_filepath", ...), which it then reports
## back periodically; those arrive here as `value_changed` and are cached
## in `values`. `subscriptions` is sent to every client as it connects.
##
## Discovery: VirtualDJ normally finds the server by mDNS/DNS-SD
## (`_os2l._tcp`), which this class does NOT advertise. Until that
## exists, point VirtualDJ at it directly with its `os2lDirectIp` option
## (e.g. `127.0.0.1:9960`).
##
##   var os2l := Os2lServer.new()
##   add_child(os2l)
##   os2l.beat.connect(func(change, pos, bpm, strength): ...)
##   os2l.start()

signal client_connected(peer: String)
signal client_disconnected(peer: String)
## A beat. `change` is true when the beat source changed (deck switch,
## new track); `pos` is the beat number; `strength` VirtualDJ's 0..100.
signal beat(change: bool, pos: int, bpm: float, strength: float)
signal button(name: String, page: String, on: bool)
signal command(id: int, param: float)
## A subscribed query reported a value (only when it differs from the
## cached one).
signal value_changed(trigger: String, value: Variant)
## Every message received, after the typed signals above.
signal message(msg: Dictionary, peer: String)
signal state_changed(listening: bool, detail: String)

const DEFAULT_PORT := 9960
## A client that sends this much without completing a JSON object is
## dropped rather than buffered forever.
const MAX_BUFFER := 1 << 20

## How many decks default_subscriptions() covers.
var deck_count := 2
## VDJscript queries to subscribe to on connect (VirtualDJ only; other
## OS2L clients ignore it). Empty = don't subscribe.
var subscriptions: PackedStringArray = default_subscriptions(2)
## How often VirtualDJ should report subscribed values, in milliseconds.
var subscription_frequency_ms := 100

## Last value reported for each subscribed query.
var values: Dictionary = {}
## The last beat: { change, pos, bpm, strength, time } (time = msec ticks).
var last_beat: Dictionary = {}

var _server := TCPServer.new()
var _port := 0
var _clients: Array = []        # [{ peer: StreamPeerTCP, name: String, buf: PackedByteArray }]


## The VDJscript queries subscribed to by default, per deck: what's
## loaded, tempo and beat phase, transport, and the mix position.
static func default_subscriptions(decks: int) -> PackedStringArray:
	var out := PackedStringArray(["crossfader"])
	for i in range(1, decks + 1):
		for q in ["get_filepath", "get_bpm", "get_beatpos", "get_firstbeat",
				"play", "level", "get_time elapsed absolute", "loop", "get_loop"]:
			out.append("deck %d %s" % [i, q])
	return out


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _process(_delta: float) -> void:
	poll()


func _exit_tree() -> void:
	stop()


## Start listening on `port` (0 = any free port; see get_port()).
func start(port: int = DEFAULT_PORT, bind_address: String = "*") -> Error:
	stop()
	var err := _server.listen(port, bind_address)
	if err != OK:
		state_changed.emit(false, "port :%d unavailable (%s)" % [port, error_string(err)])
		return err
	_port = _server.get_local_port()
	state_changed.emit(true, "listening on :%d" % _port)
	return OK


func stop() -> void:
	for c in _clients:
		c["peer"].disconnect_from_host()
		client_disconnected.emit(c["name"])
	_clients.clear()
	if _server.is_listening():
		_server.stop()
		state_changed.emit(false, "off")
	_port = 0


func is_listening() -> bool:
	return _server.is_listening()


func get_port() -> int:
	return _port


func client_count() -> int:
	return _clients.size()


## The cached value of a subscribed query, e.g. deck_value(1, "get_bpm").
func deck_value(deck: int, query: String, default: Variant = null) -> Variant:
	return values.get("deck %d %s" % [deck, query], default)


## Accept new connections and process everything received. Called every
## frame from _process(); call it yourself when not in the scene tree.
func poll() -> void:
	if not _server.is_listening():
		return
	while _server.is_connection_available():
		var peer := _server.take_connection()
		if peer == null:
			break
		peer.set_no_delay(true)
		var c := {"peer": peer, "name": "%s:%d" % [peer.get_connected_host(), peer.get_connected_port()],
			"buf": PackedByteArray()}
		_clients.append(c)
		client_connected.emit(c["name"])
		if not subscriptions.is_empty():
			_send_to(c, {"evt": "subscribe", "trigger": Array(subscriptions),
				"frequency": str(subscription_frequency_ms)})

	for c in _clients.duplicate():
		var peer: StreamPeerTCP = c["peer"]
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_drop(c)
			continue
		var n := peer.get_available_bytes()
		if n > 0:
			var got: Array = peer.get_data(n)
			if got[0] == OK:
				var buf: PackedByteArray = c["buf"]
				buf.append_array(got[1])
				c["buf"] = buf
				_drain(c)
		if c["buf"].size() > MAX_BUFFER:
			push_warning("Os2lServer: %s sent %d bytes without a complete message; dropping" % [
				c["name"], c["buf"].size()])
			_drop(c)


# ------------------------------------------------------------- SENDING --

## Light (or unlight) a DJ-side button mapped to `name` on `page`.
func send_feedback(name: String, on: bool, page: String = "") -> void:
	var msg := {"evt": "feedback", "name": name, "state": "on" if on else "off"}
	if page != "":
		msg["page"] = page
	send(msg)


## Subscribe every connected client to more VDJscript queries (they're
## also added to `subscriptions` for clients that connect later).
func subscribe(triggers: PackedStringArray) -> void:
	for t in triggers:
		if not subscriptions.has(t):
			subscriptions.append(t)
	send({"evt": "subscribe", "trigger": Array(triggers),
		"frequency": str(subscription_frequency_ms)})


## Send a raw OS2L message to every connected client.
func send(msg: Dictionary) -> void:
	for c in _clients:
		_send_to(c, msg)


func _send_to(c: Dictionary, msg: Dictionary) -> void:
	var peer: StreamPeerTCP = c["peer"]
	if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		peer.put_data(JSON.stringify(msg).to_utf8_buffer())


# ----------------------------------------------------------- RECEIVING --

func _drop(c: Dictionary) -> void:
	c["peer"].disconnect_from_host()
	_clients.erase(c)
	client_disconnected.emit(c["name"])


func _drain(c: Dictionary) -> void:
	var split := split_messages(c["buf"])
	c["buf"] = split["rest"]
	for text in split["messages"]:
		var parsed = JSON.parse_string(text)
		if parsed is Dictionary:
			handle_message(parsed, c["name"])
		else:
			push_warning("Os2lServer: unparseable message from %s: %s" % [c["name"], text.left(200)])


## Dispatch one decoded message to the typed signals, then `message`.
func handle_message(msg: Dictionary, peer: String = "") -> void:
	match str(msg.get("evt", "")):
		"beat":
			last_beat = {
				"change": _truthy(msg.get("change", false)),
				"pos": int(msg.get("pos", 0)),
				"bpm": float(msg.get("bpm", 0.0)),
				"strength": float(msg.get("strength", 0.0)),
				"time": Time.get_ticks_msec(),
			}
			beat.emit(last_beat["change"], last_beat["pos"], last_beat["bpm"], last_beat["strength"])
		"btn":
			button.emit(str(msg.get("name", "")), str(msg.get("page", "")), _truthy(msg.get("state", "")))
		"cmd":
			command.emit(int(msg.get("id", 0)), float(msg.get("param", 0.0)))
	# VirtualDJ's replies to `subscribe` carry the query and its value.
	if msg.has("trigger") and msg.has("value"):
		var t := str(msg["trigger"])
		var v: Variant = msg["value"]
		if not values.has(t) or values[t] != v:
			values[t] = v
			value_changed.emit(t, v)
	message.emit(msg, peer)


static func _truthy(v: Variant) -> bool:
	match typeof(v):
		TYPE_BOOL:
			return v
		TYPE_INT, TYPE_FLOAT:
			return v != 0
		TYPE_STRING:
			return str(v).to_lower() in ["on", "true", "yes", "1"]
	return false


## Split a byte stream of back-to-back JSON objects into complete object
## texts, returning { messages: PackedStringArray, rest: PackedByteArray }
## where `rest` is an incomplete trailing object to keep for next time.
## Braces inside strings (and escaped quotes) are handled; anything
## between objects (whitespace, newlines, NULs) is skipped. Works on
## bytes, so multi-byte UTF-8 split across reads is fine.
static func split_messages(buf: PackedByteArray) -> Dictionary:
	var messages := PackedStringArray()
	var depth := 0
	var in_string := false
	var escaped := false
	var start := -1
	var consumed := 0
	for i in range(buf.size()):
		var b := buf[i]
		if in_string:
			if escaped:
				escaped = false
			elif b == 0x5C:          # backslash
				escaped = true
			elif b == 0x22:          # "
				in_string = false
		elif b == 0x22:
			if depth > 0:
				in_string = true
		elif b == 0x7B:              # {
			if depth == 0:
				start = i
			depth += 1
		elif b == 0x7D:              # }
			if depth > 0:
				depth -= 1
				if depth == 0:
					messages.append(buf.slice(start, i + 1).get_string_from_utf8())
					consumed = i + 1
					start = -1
		elif depth == 0:
			consumed = i + 1         # junk between objects
	return {"messages": messages, "rest": buf.slice(consumed)}
