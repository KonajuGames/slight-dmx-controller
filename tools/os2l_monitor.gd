extends SceneTree
## Run an Os2lServer and print everything DJ software sends it — for
## checking what VirtualDJ actually reports.
##
##   godot --headless --script tools/os2l_monitor.gd [-- --port 9960 --decks 2]
##
## With the `addons/native` extension built, the server is advertised
## over mDNS and VirtualDJ finds it on its own; otherwise set VirtualDJ's
## `os2lDirectIp` option to this machine (e.g. 127.0.0.1:9960). Ctrl+C to
## stop.

func _initialize() -> void:
	var port := Os2lServer.DEFAULT_PORT
	var decks := 2
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		if args[i] == "--port":
			port = args[i + 1].to_int()
		elif args[i] == "--decks":
			decks = args[i + 1].to_int()

	var s := Os2lServer.new()
	s.subscriptions = Os2lServer.default_subscriptions(decks)
	s.state_changed.connect(func(on, detail): print("[OS2L] ", detail))
	s.advertising_changed.connect(func(on, detail): print("[OS2L] ", detail))
	s.client_connected.connect(func(p): print("[OS2L] connection from ", p))
	s.client_disconnected.connect(func(p): print("[OS2L] closed ", p))
	s.message.connect(func(msg, _p): print(JSON.stringify(msg)))
	root.add_child(s)
	if s.start(port) != OK:
		quit(1)
