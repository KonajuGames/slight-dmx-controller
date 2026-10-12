extends SceneTree
## Tests for Os2lServer — the OS2L (VirtualDJ sound-to-light) TCP server.
##
##   godot --headless --script tests/os2l_server_test.gd
##
## The message splitter is tested directly; the server is then driven
## over real loopback TCP by a fake DJ-software client on a free port, so
## nothing external is needed.

var _p := 0
var _f := 0


func ok(cond: bool, label: String) -> void:
	if cond:
		_p += 1
		print("  ok   ", label)
	else:
		_f += 1
		print("  FAIL ", label)


func _initialize() -> void:
	print("== OS2L server ==")
	_test_split()
	_test_handle_message()
	_test_tcp()
	_test_advertising()
	print("== %d passed, %d failed ==" % [_p, _f])
	quit(1 if _f > 0 else 0)


func _split(text: String) -> Dictionary:
	return Os2lServer.split_messages(text.to_utf8_buffer())


func _test_split() -> void:
	print("- message splitting")
	var r := _split('{"evt":"beat","pos":1}{"evt":"beat","pos":2}')
	ok(r["messages"].size() == 2 and r["rest"].is_empty(), "back-to-back objects")

	r = _split('{"evt":"beat","pos":1}{"evt":"be')
	ok(r["messages"].size() == 1 and r["rest"].get_string_from_utf8() == '{"evt":"be',
		"partial object kept as rest")

	var junk := '\r\n {"a":1}\n'.to_utf8_buffer()
	junk.append(0)
	junk.append_array('{"b":2} '.to_utf8_buffer())
	r = Os2lServer.split_messages(junk)
	ok(Array(r["messages"]) == ['{"a":1}', '{"b":2}'] and r["rest"].is_empty(),
		"whitespace / NUL between objects skipped")

	r = _split('{"trigger":"deck 1 get_text \'{x}\'","value":"a \\"}\\" b"}')
	ok(r["messages"].size() == 1 and r["rest"].is_empty(), "braces and escaped quotes inside strings")
	ok(JSON.parse_string(r["messages"][0])["value"] == 'a "}" b', "...and it still parses")

	r = _split('{"v":{"nested":{"deep":1}}}')
	ok(r["messages"].size() == 1, "nested objects")

	# Multi-byte UTF-8 split between two reads.
	var whole := '{"value":"D:/Music/Smart E’s/Tiësto.mp3"}'.to_utf8_buffer()
	var cut := whole.find(0xE2) + 1          # inside the 3-byte ’
	var r1 := Os2lServer.split_messages(whole.slice(0, cut))
	var rest: PackedByteArray = r1["rest"]
	rest.append_array(whole.slice(cut))
	var r2 := Os2lServer.split_messages(rest)
	ok(r1["messages"].is_empty() and r2["messages"].size() == 1 and
		JSON.parse_string(r2["messages"][0])["value"] == "D:/Music/Smart E’s/Tiësto.mp3",
		"UTF-8 character split across reads")


func _test_handle_message() -> void:
	print("- message dispatch")
	var s := Os2lServer.new()
	var got := {}
	s.beat.connect(func(change, pos, bpm, strength): got["beat"] = [change, pos, bpm, strength])
	s.button.connect(func(name, page, on): got["btn"] = [name, page, on])
	s.command.connect(func(id, param): got["cmd"] = [id, param])
	s.value_changed.connect(func(t, v): got["val"] = [t, v]; got["val_n"] = got.get("val_n", 0) + 1)
	s.message.connect(func(msg, _peer): got["msg_n"] = got.get("msg_n", 0) + 1)

	s.handle_message({"evt": "beat", "change": true, "pos": 33.0, "bpm": 127.98, "strength": 85.0})
	ok(got.get("beat") == [true, 33, 127.98, 85.0], "beat -> beat signal %s" % str(got.get("beat")))
	ok(s.last_beat["pos"] == 33, "last_beat cached")
	s.handle_message({"evt": "btn", "name": "Strobe", "page": "FX", "state": "on"})
	ok(got.get("btn") == ["Strobe", "FX", true], "btn -> button signal")
	s.handle_message({"evt": "btn", "name": "Strobe", "state": "off"})
	ok(got.get("btn") == ["Strobe", "", false], "btn off, no page")
	s.handle_message({"evt": "cmd", "id": 4.0, "param": 0.5})
	ok(got.get("cmd") == [4, 0.5], "cmd -> command signal")
	s.handle_message({"evt": "subscribed", "trigger": "deck 1 get_bpm", "value": 128.0})
	ok(got.get("val") == ["deck 1 get_bpm", 128.0] and s.deck_value(1, "get_bpm") == 128.0,
		"subscription value cached, deck_value()")
	s.handle_message({"evt": "subscribed", "trigger": "deck 1 get_bpm", "value": 128.0})
	ok(got.get("val_n") == 1, "unchanged value doesn't re-emit")
	s.handle_message({"evt": "something-new", "x": 1})
	ok(got.get("msg_n") == 7,"every message reaches `message` (%s)" % str(got.get("msg_n")))
	ok(s.deck_value(2, "get_bpm", -1) == -1, "deck_value default")
	s.free()


## Pump the server and the fake client until `done` returns true (or
## `timeout_ms` passes).
func _pump(s: Os2lServer, client: StreamPeerTCP, done: Callable, timeout_ms := 3000) -> bool:
	var t := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t < timeout_ms:
		s.poll()
		client.poll()
		if done.call():
			return true
		OS.delay_msec(5)
	return false


func _read_all(client: StreamPeerTCP) -> PackedByteArray:
	client.poll()
	var n := client.get_available_bytes()
	return client.get_data(n)[1] if n > 0 else PackedByteArray()


func _test_tcp() -> void:
	print("- over TCP")
	var s := Os2lServer.new()
	s.subscriptions = Os2lServer.default_subscriptions(2)
	var events := []
	s.client_connected.connect(func(p): events.append("connected " + p))
	s.client_disconnected.connect(func(p): events.append("disconnected " + p))
	var beats := []
	s.beat.connect(func(_c, pos, _b, _s): beats.append(pos))

	ok(s.start(0, "127.0.0.1") == OK and s.get_port() > 0, "listens on a free port (%d)" % s.get_port())
	var client := StreamPeerTCP.new()
	client.connect_to_host("127.0.0.1", s.get_port())
	ok(_pump(s, client, func(): return (s.client_count() == 1
		and client.get_status() == StreamPeerTCP.STATUS_CONNECTED)), "client connects")
	ok(events.size() == 1 and events[0].begins_with("connected 127.0.0.1:"), "client_connected %s" % str(events))

	# The server subscribes as soon as the client connects.
	var sub_bytes := PackedByteArray()
	_pump(s, client, func():
		sub_bytes.append_array(_read_all(client))
		return Os2lServer.split_messages(sub_bytes)["messages"].size() > 0)
	var subs: PackedStringArray = Os2lServer.split_messages(sub_bytes)["messages"]
	var sub = JSON.parse_string(subs[0]) if subs.size() > 0 else null
	ok(sub is Dictionary and sub["evt"] == "subscribe" and sub["frequency"] == "100",
		"subscribe sent on connect")
	ok(sub is Dictionary and sub["trigger"].size() == 19 and "deck 2 get_filepath" in sub["trigger"],
		"default subscriptions: crossfader + 9 per deck")

	# A message split across two writes, then two in one write.
	client.put_data('{"evt":"beat","change":false,"pos":1,"bp'.to_utf8_buffer())
	_pump(s, client, func(): return not beats.is_empty(), 200)
	ok(beats.is_empty(), "half a message isn't dispatched")
	client.put_data('m":120.0,"strength":50}{"evt":"beat","change":false,"pos":2,"bpm":120.0,"strength":50}'.to_utf8_buffer())
	ok(_pump(s, client, func(): return beats.size() == 2), "rest of it + a second message arrive")
	ok(beats == [1, 2], "in order %s" % str(beats))

	client.put_data('{"evt":"subscribed","trigger":"deck 1 get_filepath","value":"D:\\\\Music\\\\Tiësto.mp3"}'.to_utf8_buffer())
	ok(_pump(s, client, func(): return s.deck_value(1, "get_filepath") != null), "subscribed value arrives")
	ok(s.deck_value(1, "get_filepath") == "D:\\Music\\Tiësto.mp3", "UTF-8 / escapes (%s)" % str(s.deck_value(1, "get_filepath")))

	# Server -> client.
	s.send_feedback("Strobe", true, "FX")
	var fb_bytes := PackedByteArray()
	_pump(s, client, func():
		fb_bytes.append_array(_read_all(client))
		return Os2lServer.split_messages(fb_bytes)["messages"].size() > 0)
	var fbs: PackedStringArray = Os2lServer.split_messages(fb_bytes)["messages"]
	ok(fbs.size() == 1 and JSON.parse_string(fbs[0]) == {"evt": "feedback", "name": "Strobe", "state": "on", "page": "FX"},
		"send_feedback %s" % str(fbs))

	client.disconnect_from_host()
	ok(_pump(s, client, func(): return s.client_count() == 0), "disconnect noticed")
	ok(events.size() == 2 and events[1].begins_with("disconnected"), "client_disconnected")

	# A second server can't take the same port.
	var s2 := Os2lServer.new()
	ok(s2.start(s.get_port(), "127.0.0.1") != OK, "port in use -> error")
	s2.free()
	s.stop()
	ok(not s.is_listening(), "stop")
	ok(not s.is_advertised() and s.advertising_status() == "not advertised",
		"loopback-only bind isn't advertised (%s)" % s.advertising_status())
	s.free()


## mDNS advertising when the server listens on every interface: real
## registration with the native extension built, the os2lDirectIp hint
## without it.
func _test_advertising() -> void:
	print("- mDNS advertising")
	var s := Os2lServer.new()
	s.subscriptions = PackedStringArray()
	s.service_name = "sLight test %d" % (Time.get_ticks_usec() % 100000)
	var changes := []
	s.advertising_changed.connect(func(on, detail): changes.append([on, detail]))
	ok(s.start(0) == OK, "listens on all interfaces, port %d" % s.get_port())
	if not ClassDB.class_exists("MdnsAdvertiser"):
		ok(not s.is_advertised() and "os2lDirectIp" in s.advertising_status(),
			"without the extension: not advertised, points at os2lDirectIp (%s)" % s.advertising_status())
	else:
		var t := Time.get_ticks_msec()
		while not s.is_advertised() and Time.get_ticks_msec() - t < 5000:
			s.poll()
			OS.delay_msec(20)
		print("    ", s.advertising_status())
		ok(s.is_advertised() or "no DNS-SD" in s.advertising_status(), "advertised (or no DNS-SD service here)")
	s.stop()
	ok(not s.is_advertised(), "stop withdraws it")
	ok(not changes.is_empty(), "advertising_changed emitted %s" % str(changes))
	s.free()
