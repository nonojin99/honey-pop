# 셸 — 메뉴 / 플레이 / 게임오버.
#
# UI 는 .tscn 대신 코드로 만든다. 손으로 적은 씬 파일은 한 글자 어긋나면 통째로 안 열리는데,
# 이 화면은 구조가 단순해서 코드 쪽이 검증하기 쉽다.
#
# 게임오버 화면 규약(Daily Game Project 공통):
#   "내 최고 기록 N점 — 현재 M위" + 시작 화면 TOP5 리더보드
extends Node2D

const HINT := "화면을 끌어 조준하고, 손을 떼면 쏴요"

var play: Node2D = null
var _ui: CanvasLayer = null
var _menu: Control = null
var _over: Control = null
var _font: FontFile = null

var _versus: Node = null
var _in_versus := false
var _vs_start_round := 0   # 통합 테스트에서 승패 판정까지 빨리 가기 위한 시작 라운드
var _vs_pick: Control = null
var _vs_wait: Control = null
var _vs_wait_label: Label = null
var _vs_result: Control = null
var _vs_result_title: Label = null
var _vs_result_sub: Label = null

var _nick_edit: LineEdit = null
var _top_box: VBoxContainer = null
var _over_score: Label = null
var _over_rank: Label = null


func _ready() -> void:
	_font = load("res://assets/fonts/Jua-Regular.ttf")
	play = Node2D.new()
	play.set_script(load("res://scripts/play.gd"))
	add_child(play)
	play.game_over.connect(_on_game_over)

	_versus = Node.new()
	_versus.set_script(load("res://scripts/versus.gd"))
	add_child(_versus)
	_versus.state_changed.connect(_on_vs_state)
	_versus.match_started.connect(_on_vs_started)
	_versus.peer_board.connect(_on_vs_peer_board)
	_versus.attacked.connect(_on_vs_attacked)
	_versus.match_over.connect(_on_vs_over)
	play.shot_done.connect(_on_shot_done)

	_ui = CanvasLayer.new()
	add_child(_ui)
	_build_menu()
	_build_over()
	_build_versus()
	_show_menu()
	var args := OS.get_cmdline_user_args()
	if args.has("--smoke"):
		_run_smoke()
	elif args.has("--vstest"):
		_run_vstest(args)


# ── 대결 통합 테스트 ──
#   godot --headless --path . -- --vstest --size 2 --tag <공용로비와 분리할 태그> --name <이름>
# 이 프로세스를 인원수만큼 동시에 띄우면 실제 Supabase 로비에서 서로를 만난다.
# 모의 객체가 아니라 진짜 소켓으로 검증한다 — 매칭은 시차·경합이 본질이라 모의로는 못 잡는다.
func _run_vstest(args: PackedStringArray) -> void:
	var size := 2
	var tag := ""
	var nm := "봇"
	var handicap := false
	for i in args.size():
		if args[i] == "--size" and i + 1 < args.size():
			size = int(args[i + 1])
		elif args[i] == "--tag" and i + 1 < args.size():
			tag = str(args[i + 1])
		elif args[i] == "--name" and i + 1 < args.size():
			nm = str(args[i + 1])
		elif args[i] == "--handicap":
			handicap = true
		elif args[i] == "--round" and i + 1 < args.size():
			# 승패 판정 경로를 확인하려면 판이 빨리 끝나야 한다 — 높은 라운드에서 시작한다
			_vs_start_round = int(args[i + 1])
	Game.nickname = nm
	_menu.visible = false
	print("[%s] 매칭 시작 (size=%d tag=%s)" % [nm, size, tag])

	# ★ GDScript 람다는 지역 변수를 값으로 캡처한다 — bool 로 두면 바깥 루프가 끝을 모른다.
	#   참조 타입(Array)으로 넘겨야 한다 (실제로 결과가 난 뒤에도 "시간 초과"가 찍혔다).
	var done := [false]
	_versus.match_over.connect(func(win, detail):
		print("[%s] 결과 %s — %s (점수 %d)" % [nm, "승" if win else "패", detail, play.sess.score if play.sess else 0])
		done[0] = true)
	_versus.state_changed.connect(func(st, detail):
		if st == "failed":
			print("[%s] 실패 — %s" % [nm, detail])
			done[0] = true)
	_versus.match_started.connect(func(team, mem):
		print("[%s] 매칭 성립 — 팀 %d · 인원 %d · 시드 %d" % [nm, team, mem.size(), _versus.seed_value]))

	# 진단 — 어디까지 갔는지 봐야 원인을 가른다
	Net.joined.connect(func(): print("[%s] NET joined topic=%s me=%s" % [nm, Net.topic, Net.me]))
	Net.failed.connect(func(r): print("[%s] NET failed: %s" % [nm, r]))
	Net.msg.connect(func(ev, pl): print("[%s] NET msg %s from=%s" % [nm, ev, str(pl.get("from", "?"))]))

	_versus.find_match(size, tag)

	# 매칭되면 자동으로 계속 쏜다
	var t := 0.0
	while not done[0] and t < 150.0:
		await get_tree().create_timer(0.25).timeout
		t += 0.25
		if _in_versus and play.running and play.sess != null and not play.sess.over:
			if handicap:
				# 일부러 못 쏜다 — 같은 시드에 같은 봇 로직이면 둘이 동시에 죽어서
				# 승리 경로가 영영 검증되지 않는다. 한쪽을 약하게 만들어 승패를 가른다
				play.test_aim(randf_range(-Session.MAX_ANGLE, Session.MAX_ANGLE))
				play._fire()
			else:
				play.test_fire_best()
	if not done[0]:
		print("[%s] 시간 초과 — 매칭도 판정도 안 났다" % nm)
	print("[%s] VSTEST_END" % nm)
	get_tree().quit(0)


# ── 스모크 (기능 + 시각 검증) ──
#   godot --path . -- --smoke
# 실제 씬을 실제 오토로드와 함께 돌린다. --check-only 는 오토로드를 못 잡아서
# 런타임 오류를 못 걸러낸다 — 이쪽이 진짜 검증이다.
func _run_smoke() -> void:
	await get_tree().create_timer(0.8).timeout
	await _shot("01-menu")

	_on_start_single()
	await get_tree().create_timer(0.9).timeout
	await _shot("02-play")

	# 조준선은 판이 가득할 때 찍어야 의미가 있다 — 벽 반사와 착지 표시를 함께 봐야 한다
	play.test_aim(deg_to_rad(-38.0))
	await get_tree().create_timer(0.35).timeout
	await _shot("03-aim")

	# 몇 발 쏴서 터짐·낙하·파티클이 실제로 그려지는지 본다
	for i in 14:
		play.test_fire_best()
		await get_tree().create_timer(0.42).timeout
	await _shot("04-mid")

	play.test_banner(1, false)
	await get_tree().create_timer(0.45).timeout
	await _shot("04b-clear")
	await get_tree().create_timer(1.8).timeout

	play.test_kill()
	await get_tree().create_timer(1.2).timeout
	await _shot("05-over")

	print("SMOKE OK — 점수 %d · 라운드 %d · 발사 %d" % [play.sess.score, play.sess.round_no + 1, play.sess.shots_fired])
	get_tree().quit(0)


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var dir := "res://.shots/"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	img.save_png(dir + name + ".png")
	print("  캡처 %s (%dx%d)" % [name, img.get_width(), img.get_height()])


# ── 공통 위젯 ──

func _label(text: String, size: int, col: Color, align: int = HORIZONTAL_ALIGNMENT_CENTER) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", _font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	l.horizontal_alignment = align
	return l


func _button(text: String, size: int, bg: Color, fg: Color) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_override("font", _font)
	b.add_theme_font_size_override("font_size", size)
	b.add_theme_color_override("font_color", fg)
	b.add_theme_color_override("font_hover_color", fg)
	b.add_theme_color_override("font_pressed_color", fg)
	b.custom_minimum_size = Vector2(0, 96)   # 손가락으로 누르는 크기
	for state in ["normal", "hover", "pressed"]:
		var sb := StyleBoxFlat.new()
		sb.bg_color = bg if state != "pressed" else bg.darkened(0.18)
		sb.set_corner_radius_all(22)
		sb.content_margin_left = 28
		sb.content_margin_right = 28
		b.add_theme_stylebox_override(state, sb)
	return b


func _panel(margin: int = 34) -> MarginContainer:
	var m := MarginContainer.new()
	m.set_anchors_preset(Control.PRESET_FULL_RECT)
	m.add_theme_constant_override("margin_left", margin)
	m.add_theme_constant_override("margin_right", margin)
	m.add_theme_constant_override("margin_top", margin)
	m.add_theme_constant_override("margin_bottom", margin)
	return m


func _backdrop(alpha: float) -> ColorRect:
	var r := ColorRect.new()
	r.set_anchors_preset(Control.PRESET_FULL_RECT)
	r.color = Color(0.06, 0.045, 0.015, alpha)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


# ── 메뉴 ──

func _build_menu() -> void:
	_menu = Control.new()
	_menu.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ui.add_child(_menu)
	_menu.add_child(_backdrop(0.74))

	var mp := _panel()
	_menu.add_child(mp)
	var v := VBoxContainer.new()
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_theme_constant_override("separation", 14)
	mp.add_child(v)

	var bee := Control.new()
	bee.set_script(load("res://scripts/bee_badge.gd"))
	v.add_child(bee)
	v.add_child(_label("허니 팝", 76, Palette.GOLD))
	v.add_child(_label("같은 색 3개를 모으면 꿀이 되어 떨어져요", 26, Palette.INK))
	# 3초 이해 — 조작 설명은 딱 한 줄
	v.add_child(_label(HINT, 24, Palette.INK_DIM))

	var sp := Control.new()
	sp.custom_minimum_size = Vector2(0, 14)
	v.add_child(sp)

	var nick_row := HBoxContainer.new()
	nick_row.add_theme_constant_override("separation", 10)
	v.add_child(nick_row)
	var nl := _label("이름", 26, Palette.INK_DIM, HORIZONTAL_ALIGNMENT_LEFT)
	nl.custom_minimum_size = Vector2(80, 0)
	nl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	nick_row.add_child(nl)
	_nick_edit = LineEdit.new()
	_nick_edit.placeholder_text = "닉네임 (랭킹 등록용)"
	_nick_edit.max_length = 20
	_nick_edit.text = Game.nickname
	_nick_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_nick_edit.add_theme_font_override("font", _font)
	_nick_edit.add_theme_font_size_override("font_size", 28)
	_nick_edit.custom_minimum_size = Vector2(0, 66)
	nick_row.add_child(_nick_edit)

	var start := _button("혼자 하기", 40, Palette.GOLD, Color("2a1a06"))
	start.pressed.connect(_on_start_single)
	v.add_child(start)

	var versus := _button("대결하기", 34, Color("3a2a12"), Palette.GOLD)
	versus.pressed.connect(_on_start_versus)
	v.add_child(versus)

	var sp2 := Control.new()
	sp2.custom_minimum_size = Vector2(0, 10)
	v.add_child(sp2)
	v.add_child(_label("TOP 5", 26, Palette.INK_DIM))
	_top_box = VBoxContainer.new()
	_top_box.add_theme_constant_override("separation", 4)
	v.add_child(_top_box)
	_set_top_rows([])


func _set_top_rows(rows: Array) -> void:
	for c in _top_box.get_children():
		c.queue_free()
	if rows.is_empty():
		_top_box.add_child(_label("아직 기록이 없어요", 22, Palette.INK_DIM))
		return
	var i := 1
	for r in rows:
		var line := "%d.  %s  —  %s점" % [i, str(r.get("nickname", "?")), str(int(r.get("score", 0)))]
		_top_box.add_child(_label(line, 24, Palette.INK if i <= 3 else Palette.INK_DIM))
		i += 1


func _show_menu() -> void:
	_menu.visible = true
	_over.visible = false
	play.visible = true
	play.stop()
	play.show_attract()   # 메뉴 뒤에 벌과 벌집이 보이게 — 검은 여백은 첫인상을 버린다
	_load_top()


func _load_top() -> void:
	var rows: Array = await Game.fetch_top(5)
	if is_instance_valid(_top_box):
		_set_top_rows(rows)


# ── 시작 ──

func _remember_nick() -> void:
	var n := _nick_edit.text.strip_edges()
	if n != "":
		Game.nickname = n
		Game.save()


func _on_start_single() -> void:
	Sfx.ui()
	_remember_nick()
	_menu.visible = false
	_over.visible = false
	play.visible = true
	play.start()
	Game.log_event("start")


func _on_start_versus() -> void:
	Sfx.ui()
	_remember_nick()
	if Game.nickname.strip_edges() == "":
		_toast("이름을 먼저 넣어 주세요")
		return
	_menu.visible = false
	_vs_pick.visible = true


# ── 대결 UI ──

func _build_versus() -> void:
	# 1) 모드 고르기
	_vs_pick = Control.new()
	_vs_pick.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ui.add_child(_vs_pick)
	_vs_pick.add_child(_backdrop(0.88))
	var v := VBoxContainer.new()
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_theme_constant_override("separation", 16)
	var mp := _panel()
	_vs_pick.add_child(mp)
	mp.add_child(v)
	v.add_child(_label("대결 모드", 56, Palette.GOLD))
	v.add_child(_label("큰 덩어리를 떨어뜨릴수록 상대에게 방해 구슬이 갑니다", 22, Palette.INK_DIM))
	var b1 := _button("1 VS 1", 40, Palette.GOLD, Color("2a1a06"))
	b1.pressed.connect(func(): _seek(2))
	v.add_child(b1)
	var b2 := _button("2 VS 2", 40, Color("3a2a12"), Palette.GOLD)
	b2.pressed.connect(func(): _seek(4))
	v.add_child(b2)
	var back := _button("돌아가기", 28, Color("2a2010"), Palette.INK_DIM)
	back.pressed.connect(func():
		Sfx.ui()
		_vs_pick.visible = false
		_show_menu())
	v.add_child(back)
	_vs_pick.visible = false

	# 2) 상대 기다리기
	_vs_wait = Control.new()
	_vs_wait.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ui.add_child(_vs_wait)
	_vs_wait.add_child(_backdrop(0.90))
	var v2 := VBoxContainer.new()
	v2.alignment = BoxContainer.ALIGNMENT_CENTER
	v2.add_theme_constant_override("separation", 18)
	var mp2 := _panel()
	_vs_wait.add_child(mp2)
	mp2.add_child(v2)
	var bee := Control.new()
	bee.set_script(load("res://scripts/bee_badge.gd"))
	v2.add_child(bee)
	_vs_wait_label = _label("상대를 찾는 중…", 36, Palette.INK)
	v2.add_child(_vs_wait_label)
	var cancel := _button("취소", 30, Color("3a2a12"), Palette.GOLD)
	cancel.pressed.connect(func():
		Sfx.ui()
		_versus.cancel()
		_vs_wait.visible = false
		_show_menu())
	v2.add_child(cancel)
	_vs_wait.visible = false

	# 3) 결과
	_vs_result = Control.new()
	_vs_result.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ui.add_child(_vs_result)
	_vs_result.add_child(_backdrop(0.90))
	var v3 := VBoxContainer.new()
	v3.alignment = BoxContainer.ALIGNMENT_CENTER
	v3.add_theme_constant_override("separation", 16)
	var mp3 := _panel()
	_vs_result.add_child(mp3)
	mp3.add_child(v3)
	_vs_result_title = _label("", 60, Palette.GOLD)
	v3.add_child(_vs_result_title)
	_vs_result_sub = _label("", 26, Palette.INK_DIM)
	v3.add_child(_vs_result_sub)
	var again := _button("다시 대결", 36, Palette.GOLD, Color("2a1a06"))
	again.pressed.connect(func():
		Sfx.ui()
		_vs_result.visible = false
		_vs_pick.visible = true)
	v3.add_child(again)
	var home := _button("처음으로", 28, Color("3a2a12"), Palette.GOLD)
	home.pressed.connect(func():
		Sfx.ui()
		_end_versus()
		_vs_result.visible = false
		_show_menu())
	v3.add_child(home)
	_vs_result.visible = false


func _seek(size: int) -> void:
	Sfx.ui()
	_vs_pick.visible = false
	_vs_wait.visible = true
	_vs_wait_label.text = "상대를 찾는 중…"
	_versus.find_match(size)


func _on_vs_state(st: String, detail: String) -> void:
	if st == "failed":
		_vs_wait.visible = false
		_show_menu()
		_toast(detail)
	elif _vs_wait_label != null and detail != "":
		_vs_wait_label.text = detail


func _on_vs_started(team: int, mem: Array) -> void:
	_in_versus = true
	_vs_wait.visible = false
	_menu.visible = false
	_over.visible = false
	play.visible = true
	play.versus_mode = true
	play.peers = []
	for k in mem:
		if str(k) != Net.me:
			play.peers.append({"key": str(k), "name": _versus.team_name(int(_versus.teams.get(k, 1))),
				"team": 1 if int(_versus.teams.get(k, 1)) != team else 0,
				"board": "", "score": 0, "dead": false})
	play.start(_versus.seed_value, _vs_start_round)
	Game.log_event("start")


func _on_vs_peer_board(key: String, board: String, score: int, dead: bool) -> void:
	for p in play.peers:
		if str(p["key"]) == key:
			p["board"] = board
			p["score"] = score
			p["dead"] = dead
			return


func _on_vs_attacked(amount: int) -> void:
	if play.sess != null:
		play.sess.receive_attack(amount)
		Sfx.warn()


func _on_shot_done(res: Dictionary) -> void:
	if not _in_versus:
		return
	var atk := Session.attack_of(int(res.get("popped", 0)), int(res.get("dropped", 0)))
	if atk > 0:
		_versus.send_attack(atk)


func _on_vs_over(win: bool, detail: String) -> void:
	play.stop()
	_vs_result_title.text = "이겼어요!" if win else "졌어요"
	_vs_result_title.add_theme_color_override("font_color", Palette.GOLD if win else Palette.INK_DIM)
	_vs_result_sub.text = "%s · %d점" % [detail, play.sess.score if play.sess != null else 0]
	_vs_result.visible = true
	if win:
		Sfx.round_clear()
	_end_versus()


func _end_versus() -> void:
	_in_versus = false
	play.versus_mode = false
	play.peers = []
	Net.close()


func _process(_delta: float) -> void:
	if _in_versus and play.sess != null and play.running:
		_versus.sync_board(play.sess)


var _toast_label: Label = null

func _toast(msg: String) -> void:
	if _toast_label != null and is_instance_valid(_toast_label):
		_toast_label.queue_free()
	_toast_label = _label(msg, 28, Palette.GOLD)
	_toast_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_toast_label.position = Vector2(get_viewport_rect().size.x * 0.5 - 300.0, get_viewport_rect().size.y - 200.0)
	_toast_label.custom_minimum_size = Vector2(600, 0)
	_menu.add_child(_toast_label)
	var t := get_tree().create_timer(2.0)
	t.timeout.connect(func():
		if is_instance_valid(_toast_label):
			_toast_label.queue_free())


# ── 게임오버 ──

func _build_over() -> void:
	_over = Control.new()
	_over.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ui.add_child(_over)
	_over.add_child(_backdrop(0.90))

	var mp := _panel()
	_over.add_child(mp)
	var v := VBoxContainer.new()
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_theme_constant_override("separation", 16)
	mp.add_child(v)

	v.add_child(_label("벌집이 내려앉았어요", 44, Palette.INK))
	_over_score = _label("0점", 76, Palette.GOLD)
	v.add_child(_over_score)
	_over_rank = _label("", 28, Palette.INK_DIM)
	v.add_child(_over_rank)

	var again := _button("다시 하기", 40, Palette.GOLD, Color("2a1a06"))
	again.pressed.connect(_on_start_single)
	v.add_child(again)

	var home := _button("처음으로", 30, Color("3a2a12"), Palette.GOLD)
	home.pressed.connect(func():
		Sfx.ui()
		_show_menu())
	v.add_child(home)


func _on_game_over() -> void:
	if _in_versus:
		# 대결에서는 랭킹이 아니라 "내가 탈락했다"를 알린다. 승패 판정은 versus 가 한다
		_versus.report_dead()
		return
	var sess: Session = play.sess
	var score: int = sess.score
	var is_best := Game.note_result(score, sess.round_no)
	Game.log_event("over", score)

	_over_score.text = "%d점" % score
	_over_rank.text = "라운드 %d 도달 · 기록 등록 중…" % (sess.round_no + 1)
	_over.visible = true
	_menu.visible = false

	# 랭킹은 실패해도 게임 흐름을 막지 않는다
	var nick := Game.nickname.strip_edges()
	if nick == "":
		_over_rank.text = "내 최고 기록 %d점 · 이름을 넣으면 랭킹에 올라가요" % Game.best_score
		return
	var res: Dictionary = await Game.submit_and_rank(nick, score)
	if not is_instance_valid(_over_rank):
		return
	if bool(res.get("ok", false)):
		_over_rank.text = "내 최고 기록 %d점 — 현재 %d위" % [int(res["best"]), int(res["rank"])]
	else:
		_over_rank.text = "내 최고 기록 %d점 · 랭킹 서버에 연결할 수 없어요" % Game.best_score
	if is_best:
		Sfx.round_clear()
