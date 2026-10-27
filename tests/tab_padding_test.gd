extends SceneTree
## Every tab in the app has the same inset from its tab container's edge
## (TabPadding): a TabContainer is padded as a whole, or else each of its
## pages is — a TabPadding.page(), or a TabContainer of its own that's
## padded — except the full-bleed ones listed here. A new tab that isn't
## fails this.
##
##   godot --headless --script tests/tab_padding_test.gd

var _p := 0
var _f := 0

## Pages meant to run edge to edge.
const FULL_BLEED := ["VisualizerPanel"]


func ok(cond: bool, label: String) -> void:
	if cond:
		_p += 1
		print("  ok   ", label)
	else:
		_f += 1
		print("  FAIL ", label)


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	print("== Tab padding ==")
	var TP: GDScript = load("res://scripts/tab_padding.gd")
	var main: Control = load("res://main.tscn").instantiate()
	main.last_show_store = "user://_tab_padding_test_last.json"
	main.ui_state_store = "user://_tab_padding_test_ui.json"
	root.add_child(main)
	await process_frame
	await process_frame
	var tabs: Array = []
	_find_tabs(main, tabs)
	ok(tabs.size() >= 4, "the app's tab containers found (%d)" % tabs.size())
	for tc in tabs:
		var titles: Array = []
		for i in range(tc.get_tab_count()):
			titles.append(tc.get_tab_title(i))
		var what := "/".join(titles) if not titles.is_empty() else String(tc.get_path())
		if TP.is_padded(tc):
			ok(true, "%s: padded" % what)
			continue
		for i in range(tc.get_tab_count()):
			var page: Control = tc.get_tab_control(i)
			var cls := _class_name(page)
			var fine: bool = TP.is_page(page) or (page is TabContainer and TP.is_padded(page)) \
				or cls in FULL_BLEED
			ok(fine, "%s › %s: %s" % [what, tc.get_tab_title(i),
				"full-bleed" if cls in FULL_BLEED else ("padded" if fine else "NOT padded")])
	main.queue_free()
	await process_frame
	for f in ["_tab_padding_test_last.json", "_tab_padding_test_ui.json"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path("user://" + f))
	print("== %d passed, %d failed ==" % [_p, _f])
	quit(1 if _f > 0 else 0)


func _find_tabs(n: Node, out: Array) -> void:
	if n is TabContainer:
		out.append(n)
	for c in n.get_children():
		_find_tabs(c, out)


func _class_name(n: Node) -> String:
	var s: Script = n.get_script()
	return s.get_global_name() if s != null else n.get_class()
