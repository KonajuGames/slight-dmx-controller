class_name GroupsPanel
extends VBoxContainer
## Groups tab: named sets of patched fixtures. An effect can target a
## group instead of "every fixture with role X on universe Y".
##
## A group is { "name": String, "members": Array } where each member is
## a two-element [universe_index, fixture_id]. The shell owns the list
## and shares the reference here.

signal groups_changed

var groups: Array = []                 # shared reference, owned by the shell
var fixtures_provider := Callable()     # func() -> Array of {u, id, label}

var group_list: ItemList
var members_box: VBoxContainer
var status_label: Label


func _ready() -> void:
	add_theme_constant_override("separation", 6)
	custom_minimum_size = Vector2(300, 0)

	var title := Label.new()
	title.text = "Fixture Groups"
	add_child(title)

	var top := _flow()
	var new_btn := Button.new()
	new_btn.text = "New Group"
	new_btn.pressed.connect(_new_group)
	top.add_child(new_btn)
	var ren_btn := Button.new()
	ren_btn.text = "Rename"
	ren_btn.pressed.connect(_rename_group)
	top.add_child(ren_btn)
	var del_btn := Button.new()
	del_btn.text = "Delete"
	del_btn.pressed.connect(_delete_group)
	top.add_child(del_btn)
	add_child(top)

	group_list = ItemList.new()
	group_list.custom_minimum_size = Vector2(0, 90)
	group_list.item_selected.connect(func(_i: int): _refresh_members())
	add_child(group_list)

	add_child(HSeparator.new())

	var hdr := _flow()
	hdr.add_child(_mklabel("Fixtures in group:"))
	var refresh_btn := Button.new()
	refresh_btn.text = "Sync to patch"
	refresh_btn.pressed.connect(_refresh_members)
	hdr.add_child(refresh_btn)
	add_child(hdr)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	members_box = VBoxContainer.new()
	members_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(members_box)

	status_label = Label.new()
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(status_label)

	_refresh_list()


# ---------------------------------------------------------------- HELPERS --

func _flow(h: int = 6, v: int = 4) -> HFlowContainer:
	var f := HFlowContainer.new()
	f.add_theme_constant_override("h_separation", h)
	f.add_theme_constant_override("v_separation", v)
	return f


func _mklabel(t: String) -> Label:
	var l := Label.new()
	l.text = t
	return l


func _sel() -> int:
	var s := group_list.get_selected_items()
	return s[0] if s.size() > 0 else -1


func _current() -> Dictionary:
	var i := _sel()
	return groups[i] if i >= 0 and i < groups.size() else {}


func group_names() -> Array:
	var out: Array = []
	for g in groups:
		out.append(String(g["name"]))
	return out


func _member_has(members: Array, u: int, id: int) -> int:
	for i in range(members.size()):
		if int(members[i][0]) == u and int(members[i][1]) == id:
			return i
	return -1


# ----------------------------------------------------------------- ACTIONS --

func _new_group() -> void:
	groups.append({"name": "Group %d" % (groups.size() + 1), "members": []})
	_refresh_list()
	group_list.select(groups.size() - 1)
	_refresh_members()
	groups_changed.emit()


func _delete_group() -> void:
	var i := _sel()
	if i == -1:
		return
	groups.remove_at(i)
	_refresh_list()
	if not groups.is_empty():
		group_list.select(min(i, groups.size() - 1))
	_refresh_members()
	groups_changed.emit()


func _rename_group() -> void:
	var g := _current()
	if g.is_empty():
		return
	var dlg := AcceptDialog.new()
	dlg.title = "Rename Group"
	var le := LineEdit.new()
	le.text = String(g["name"])
	le.custom_minimum_size = Vector2(220, 0)
	dlg.add_child(le)
	dlg.register_text_enter(le)
	add_child(dlg)
	dlg.confirmed.connect(func():
		var t := le.text.strip_edges()
		if t != "":
			g["name"] = t
			_refresh_list()
			groups_changed.emit()
		dlg.queue_free()
	)
	dlg.canceled.connect(func(): dlg.queue_free())
	dlg.popup_centered()
	le.grab_focus()
	le.select_all()


func _refresh_list() -> void:
	var keep := _sel()
	group_list.clear()
	for g in groups:
		group_list.add_item("%s  (%d fixtures)" % [g["name"], (g["members"] as Array).size()])
	if keep >= 0 and keep < group_list.item_count:
		group_list.select(keep)


func _refresh_members() -> void:
	for c in members_box.get_children():
		c.queue_free()
	var g := _current()
	if g.is_empty():
		status_label.text = "No group selected."
		return
	var members: Array = g["members"]
	var fixtures: Array = fixtures_provider.call() if fixtures_provider.is_valid() else []

	# prune members whose fixture is gone
	var live := {}
	for fx in fixtures:
		live["%d/%d" % [int(fx["u"]), int(fx["id"])]] = true
	for i in range(members.size() - 1, -1, -1):
		if not live.has("%d/%d" % [int(members[i][0]), int(members[i][1])]):
			members.remove_at(i)

	if fixtures.is_empty():
		status_label.text = "Patch some fixtures first."
	else:
		status_label.text = "%d of %d fixtures in '%s'." % [members.size(), fixtures.size(), g["name"]]

	for fx in fixtures:
		var u := int(fx["u"])
		var id := int(fx["id"])
		var cb := CheckBox.new()
		cb.text = String(fx["label"])
		cb.button_pressed = _member_has(members, u, id) != -1
		cb.toggled.connect(func(on: bool):
			var at := _member_has(members, u, id)
			if on and at == -1:
				members.append([u, id])
			elif not on and at != -1:
				members.remove_at(at)
			_refresh_list()
			status_label.text = "%d fixtures in '%s'." % [members.size(), g["name"]]
			groups_changed.emit()
		)
		members_box.add_child(cb)


func sync_to_patch() -> void:
	_refresh_list()
	_refresh_members()


# ------------------------------------------------------- SERIALIZATION --

func to_dict() -> Dictionary:
	var arr: Array = []
	for g in groups:
		var mem: Array = []
		for m in g["members"]:
			mem.append([int(m[0]), int(m[1])])
		arr.append({"name": String(g["name"]), "members": mem})
	return {"groups": arr}


func from_dict(d: Dictionary) -> void:
	groups.clear()
	for g in d.get("groups", []):
		if not (g is Dictionary):
			continue
		var mem: Array = []
		for m in g.get("members", []):
			if m is Array and m.size() >= 2:
				mem.append([int(m[0]), int(m[1])])
		groups.append({"name": String(g.get("name", "Group")), "members": mem})
	_refresh_list()
	if not groups.is_empty():
		group_list.select(0)
	_refresh_members()
