# 판 화면 — 그리기 + 조작. 규칙은 하나도 여기 없다(session.gd 가 전부 쥔다).
#
# ── 2축이 손에 닿는 지점 ──
# 조준선은 벽 반사까지 그려 준다. 그게 축1의 도구다. 대신 **조준하는 동안 꽃가루가 흐른다** —
# 조준선을 오래 볼수록 정확해지지만 그만큼 벌집이 내려온다. 도구의 값을 축2로 치르는 구조라,
# 두 축이 화면 위에서 직접 맞물린다.
#
# ── 좌표 ──
# session/board 는 unit 좌표만 안다. 여기서 unit → 픽셀 배율(_scale)과 원점(_origin)만 씌운다.
# 화면 크기가 판정에 영향을 주면 그게 공정성 버그다 — 배율은 그리기에만 쓴다.
extends Node2D

signal shot_done(result: Dictionary)
signal game_over()

const AIM_DEAD_ZONE := 18.0     # 이보다 짧게 끌면 조준으로 안 본다 (오탭 방지)
const FLIGHT_SPEED := 78.0      # unit/초
const HUD_TOP := 132.0
const BOARD_TOP := 214.0
const SIDE_MARGIN := 22.0

var sess: Session = null
var running := false
var attract := false     # 메뉴 뒤 배경으로만 그리는 상태 (조작·꽃가루 없음)

# ── 대결 모드 ──
# 상대 판을 오른쪽 열에 작게 띄운다. 내 판 위에 겹쳐 그리면 조준을 가리므로,
# 대결일 때는 아예 판 폭을 줄여 자리를 만든다.
var versus_mode := false
var peers: Array = []    # [{key, name, team, board(String), score, dead}]
const PEER_COL_RATIO := 0.26

var _font: FontFile = null
var _scale := 30.0
var _origin := Vector2.ZERO
var _aim_angle := 0.0
var _aiming := false
var _touch_id := -1

# 비행 중인 구슬 — 이 동안은 입력도 꽃가루도 멈춘다(궤적이 그 사이에 바뀌면 안 되므로)
var _fly_path: Array = []
var _fly_t := 0.0
var _fly_len := 0.0
var _fly_color := 0
var _flying := false

var _particles: Array = []      # {pos, vel, col, life, max_life, r}
var _shake := 0.0
var _flash := 0.0               # 고갈 경고 점멸
var _pop_labels: Array = []     # {pos, text, life}

# 라운드 클리어 배너 — 이 동안은 꽃가루도 멈추고 입력도 안 받는다.
# 축하하는 2초에 게이지가 새면 축하가 아니라 벌칙이 된다
const BANNER_TIME := 2.0
var _banner_t := 0.0
var _banner_text := ""
var _banner_sub := ""


func _ready() -> void:
	_font = load("res://assets/fonts/Jua-Regular.ttf")
	set_process(true)
	set_process_unhandled_input(true)


func start(seed_value: int = 0, start_round: int = 0) -> void:
	var sv := seed_value if seed_value != 0 else int(Time.get_unix_time_from_system()) ^ (randi() & 0xFFFF)
	sess = Session.new(sv, start_round)
	running = true
	attract = false
	_flying = false
	_particles.clear()
	_pop_labels.clear()
	_aim_angle = 0.0
	_aiming = false
	_banner_t = 0.0
	queue_redraw()


func stop() -> void:
	running = false


# 메뉴 배경용 — 조작도 시간도 흐르지 않는, 보기 좋은 판 하나
func show_attract() -> void:
	sess = Session.new(20260905, 1)
	running = false
	attract = true
	_flying = false
	_particles.clear()
	_pop_labels.clear()
	_aim_angle = deg_to_rad(-16.0)
	queue_redraw()


# ── 좌표 변환 ──

func _layout() -> void:
	var vp := get_viewport_rect().size
	var avail_w := vp.x - SIDE_MARGIN * 2.0
	if versus_mode:
		avail_w -= vp.x * PEER_COL_RATIO
	var s := avail_w / Board.W
	# 세로가 모자라면 세로에 맞춘다 — 발사대까지 다 들어와야 한다
	var need_h := (float(Board.ROWS) * Board.ROW_H + 4.2)
	var avail_h := vp.y - BOARD_TOP - 96.0
	s = minf(s, avail_h / need_h)
	_scale = s
	var field_w := vp.x - (vp.x * PEER_COL_RATIO if versus_mode else 0.0)
	_origin = Vector2((field_w - Board.W * s) * 0.5, BOARD_TOP)


func _to_px(u: Vector2) -> Vector2:
	return _origin + u * _scale


func _process(delta: float) -> void:
	if sess == null:
		return
	_shake = maxf(0.0, _shake - delta * 4.0)
	_flash += delta
	_step_particles(delta)

	if _banner_t > 0.0:
		_banner_t -= delta
	elif running and not sess.over:
		if _flying:
			_advance_flight(delta)
		else:
			# ★ 축2 — 조준하고 있는 이 순간에도 꽃가루가 흐른다
			var before_desc := sess.descends
			sess.tick(delta)
			if sess.descends > before_desc:
				Sfx.dry()
				_shake = 1.0
			if sess.over:
				_end()
			elif sess.pollen < Difficulty.POLLEN_MAX * 0.22:
				pass
	queue_redraw()


func _end() -> void:
	if not running:
		return
	running = false
	Sfx.game_over()
	game_over.emit()


# ── 입력: 아무 데나 끌어서 조준, 떼면 발사 ──

func _unhandled_input(event: InputEvent) -> void:
	if not running or sess == null or sess.over or _flying or _banner_t > 0.0:
		return
	if event is InputEventScreenTouch:
		var t := event as InputEventScreenTouch
		if t.pressed and _touch_id == -1:
			_touch_id = t.index
			_aiming = true
			_update_aim(t.position)
		elif not t.pressed and t.index == _touch_id:
			_touch_id = -1
			if _aiming:
				_aiming = false
				_fire()
	elif event is InputEventScreenDrag:
		var d := event as InputEventScreenDrag
		if d.index == _touch_id:
			_update_aim(d.position)


func _update_aim(pos: Vector2) -> void:
	var origin := _to_px(sess.shooter_pos())
	var v := pos - origin
	# 발사대보다 아래를 누르면 각도가 뒤집힌다 — 위쪽 성분만 인정한다
	if v.y > -AIM_DEAD_ZONE:
		v.y = -AIM_DEAD_ZONE
	_aim_angle = clampf(atan2(v.x, -v.y), -Session.MAX_ANGLE, Session.MAX_ANGLE)


func _fire() -> void:
	var dir := Vector2(sin(_aim_angle), -cos(_aim_angle))
	var shot := sess.board.trace_shot(sess.shooter_pos(), dir)
	_fly_path = shot["path"]
	if _fly_path.size() < 2:
		return
	_fly_len = 0.0
	for i in range(1, _fly_path.size()):
		_fly_len += (_fly_path[i] as Vector2).distance_to(_fly_path[i - 1])
	_fly_color = sess.cur_color
	_fly_t = 0.0
	_flying = true
	Sfx.shoot()


func _advance_flight(delta: float) -> void:
	_fly_t += delta * FLIGHT_SPEED
	if _fly_t < _fly_len:
		return
	_flying = false
	# 판이 비행 중에 안 바뀌었으므로 session 이 다시 추적해도 같은 결과가 나온다.
	# 규칙 판정은 언제나 session 이 한다 — 화면이 판정에 끼어들지 않는다.
	var res := sess.fire(_aim_angle, 0.0)
	_on_result(res)


func _on_result(res: Dictionary) -> void:
	var popped: int = int(res.get("popped", 0))
	var dropped: int = int(res.get("dropped", 0))
	if popped > 0:
		Sfx.pop(popped + dropped)
		_burst(int(res.get("r", 0)), int(res.get("c", 0)), popped + dropped)
		_pop_labels.append({
			"pos": _to_px(Board.cell_pos(int(res.get("r", 0)), int(res.get("c", 0)))),
			"text": "+%d" % (popped * Session.SCORE_POP + dropped * Session.SCORE_DROP),
			"life": 0.9,
		})
		if dropped > 0:
			Sfx.drop(dropped)
			_shake = maxf(_shake, 0.5)
	else:
		Sfx.stick()
	if bool(res.get("cleared", false)):
		# session 은 이미 다음 라운드로 넘어가 있다 — round_no 가 곧 방금 끝낸 라운드의 1-based 번호
		_show_clear_banner(sess.round_no, bool(res.get("sweep", false)))
	if bool(res.get("dry", false)):
		Sfx.dry()
	shot_done.emit(res)
	if sess.over:
		_end()


# 라운드 클리어 축하 — 빵빠레 + 깜빡이는 문구 + 색색 꽃가루. BANNER_TIME 동안 판을 멈춘다
func _show_clear_banner(round_done: int, sweep: bool) -> void:
	_banner_t = BANNER_TIME
	_banner_text = "라운드 %d 클리어!" % round_done
	_banner_sub = "벌집을 싹 비웠어요! 보너스 꿀" if sweep else "다음 벌집이 내려와요"
	_shake = 0.8
	Sfx.fanfare()
	_confetti()


# 화면 위쪽에서 색색의 꽃가루가 쏟아진다
func _confetti() -> void:
	var vp := get_viewport_rect().size
	for i in 90:
		var x := randf_range(vp.x * 0.05, vp.x * 0.95)
		_particles.append({
			"pos": Vector2(x, randf_range(-40.0, vp.y * 0.25)),
			"vel": Vector2(randf_range(-90.0, 90.0), randf_range(40.0, 180.0)),
			"col": Palette.bubble_color(randi() % Palette.BUBBLE.size()),
			"life": randf_range(1.2, 2.0), "max_life": 2.0, "r": randf_range(3.0, 7.0),
		})


# ── 파티클 ──

func _burst(r: int, c: int, n: int) -> void:
	var at := _to_px(Board.cell_pos(r, c))
	for i in mini(46, 8 + n * 4):
		var a := randf() * TAU
		var sp := randf_range(60.0, 320.0)
		_particles.append({
			"pos": at, "vel": Vector2(cos(a), sin(a)) * sp,
			"col": Palette.bubble_color(sess.cur_color if sess else 0),
			"life": randf_range(0.35, 0.8), "max_life": 0.8, "r": randf_range(2.5, 6.5),
		})


func _step_particles(delta: float) -> void:
	var keep: Array = []
	for p in _particles:
		p["life"] -= delta
		if p["life"] <= 0.0:
			continue
		var slow: bool = float(p["max_life"]) >= 2.0     # 꽃가루(축하)는 살랑살랑 떨어진다
		p["vel"] = (p["vel"] as Vector2) * (0.985 if slow else 0.93) + Vector2(0, (140.0 if slow else 620.0) * delta)
		p["pos"] = (p["pos"] as Vector2) + (p["vel"] as Vector2) * delta
		keep.append(p)
	_particles = keep
	var kl: Array = []
	for l in _pop_labels:
		l["life"] -= delta
		if l["life"] > 0.0:
			l["pos"] = (l["pos"] as Vector2) + Vector2(0, -46.0 * delta)
			kl.append(l)
	_pop_labels = kl


# ── 그리기 ──

func _draw() -> void:
	if sess == null:
		return
	_layout()
	var vp := get_viewport_rect().size
	var off := Vector2(sin(_shake * 34.0) * _shake * 7.0, cos(_shake * 27.0) * _shake * 4.0)
	draw_set_transform(off, 0.0, Vector2.ONE)

	_draw_bg(vp)
	if not attract:
		_draw_deadline(vp)
	_draw_board()
	if running and not _flying and not sess.over:
		_draw_aim()
	_draw_flying()
	if not attract:
		_draw_shooter()
	for p in _particles:
		var col: Color = p["col"]
		col.a = clampf(float(p["life"]) / float(p["max_life"]), 0.0, 1.0)
		draw_circle(p["pos"], p["r"], col)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	if not attract:
		_draw_hud(vp)
	if versus_mode:
		_draw_peers(vp)
	for l in _pop_labels:
		var a := clampf(float(l["life"]) / 0.9, 0.0, 1.0)
		var c := Palette.GOLD
		c.a = a
		_text(str(l["text"]), l["pos"], 40, c, HORIZONTAL_ALIGNMENT_CENTER)
	if _banner_t > 0.0:
		_draw_banner(vp)


# 축하 문구 — 2초 동안 네 번쯤 깜빡인다. 마지막 0.4초는 서서히 사라진다
func _draw_banner(vp: Vector2) -> void:
	var elapsed := BANNER_TIME - _banner_t
	var blink := 0.55 + 0.45 * absf(sin(elapsed * 6.5))
	var fade := clampf(_banner_t / 0.4, 0.0, 1.0)
	var band_y := vp.y * 0.36
	var band_h := 190.0
	draw_rect(Rect2(0, band_y, vp.x, band_h), Color(0, 0, 0, 0.62 * fade))
	draw_rect(Rect2(0, band_y, vp.x, 4), Color(Palette.GOLD, 0.8 * fade))
	draw_rect(Rect2(0, band_y + band_h - 4, vp.x, 4), Color(Palette.GOLD, 0.8 * fade))
	var col := Palette.GOLD
	col.a = blink * fade
	_text(_banner_text, Vector2(vp.x * 0.5, band_y + 92.0), 64, col, HORIZONTAL_ALIGNMENT_CENTER)
	var sub := Palette.INK
	sub.a = fade
	_text(_banner_sub, Vector2(vp.x * 0.5, band_y + 150.0), 28, sub, HORIZONTAL_ALIGNMENT_CENTER)


func _draw_bg(vp: Vector2) -> void:
	# 세로 그러데이션을 몇 겹의 사각형으로 (셰이더 없이, 웹 빌드 호환)
	var bands := 20
	for i in bands:
		var t := float(i) / float(bands - 1)
		var col := Palette.BG_TOP.lerp(Palette.BG_BOT, t)
		draw_rect(Rect2(0, vp.y * float(i) / float(bands), vp.x, vp.y / float(bands) + 1.0), col)
	# 벌집 배경 무늬 — 아주 흐리게, 세계관을 바닥에 깔아 둔다
	var r := _scale * 1.35
	var hh := r * 1.5
	var rows := int(vp.y / hh) + 2
	var cols := int(vp.x / (r * 1.74)) + 2
	for gy in rows:
		for gx in cols:
			var cx := float(gx) * r * 1.74 + (r * 0.87 if gy % 2 == 1 else 0.0)
			var cy := float(gy) * hh
			_hex(Vector2(cx, cy), r * 0.92, Color(1, 0.78, 0.35, 0.035))


func _hex(c: Vector2, r: float, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in 6:
		var a := -PI * 0.5 + TAU * float(i) / 6.0
		pts.append(c + Vector2(cos(a), sin(a)) * r)
	pts.append(pts[0])
	draw_polyline(pts, col, 2.0)


func _draw_deadline(vp: Vector2) -> void:
	var y := _to_px(Vector2(0, float(Board.DEAD_ROW) * Board.ROW_H)).y
	var low := sess.board.lowest_row()
	var near: bool = low >= Board.DEAD_ROW - 2
	var col := Palette.DANGER if near else Color(1, 0.5, 0.35, 0.35)
	if near:
		col.a = 0.55 + 0.45 * sin(_flash * 8.0)
	var x := _origin.x
	while x < _origin.x + Board.W * _scale:
		draw_line(Vector2(x, y), Vector2(x + 14.0, y), col, 3.0)
		x += 26.0
	_text("위험선", Vector2(_origin.x + 10.0, y - 30.0), 22, col, HORIZONTAL_ALIGNMENT_LEFT)


func _draw_board() -> void:
	var rad := _scale * Board.R
	for r in Board.ROWS:
		for c in Board.COLS:
			var v: int = sess.board.grid[r][c]
			if v == Board.EMPTY:
				continue
			Palette.draw_bubble(self, _to_px(Board.cell_pos(r, c)), rad, v)


# 조준선 — 벽 반사까지 점선으로. 이게 축1의 도구다
func _draw_aim() -> void:
	var dir := Vector2(sin(_aim_angle), -cos(_aim_angle))
	var shot := sess.board.trace_shot(sess.shooter_pos(), dir, 0.16)
	var path: Array = shot["path"]
	if path.size() < 2:
		return
	var col := Palette.bubble_color(sess.cur_color)
	col.a = 0.75 if _aiming else 0.34
	# 점선: 일정 간격으로 작은 원을 찍는다
	var acc := 0.0
	var step := 0.62
	for i in range(1, path.size()):
		var a: Vector2 = path[i - 1]
		var b: Vector2 = path[i]
		var seg := a.distance_to(b)
		var t := 0.0
		while t < seg:
			acc += 0.0
			var p := a.lerp(b, t / maxf(seg, 0.0001))
			draw_circle(_to_px(p), maxf(2.0, _scale * 0.10), col)
			t += step
	if bool(shot["hit"]):
		var target := _to_px(Board.cell_pos(int(shot["r"]), int(shot["c"])))
		draw_arc(target, _scale * Board.R * 0.95, 0.0, TAU, 24, col, 3.0)


func _draw_flying() -> void:
	if not _flying or _fly_path.size() < 2:
		return
	var d := _fly_t
	for i in range(1, _fly_path.size()):
		var a: Vector2 = _fly_path[i - 1]
		var b: Vector2 = _fly_path[i]
		var seg := a.distance_to(b)
		if d <= seg:
			Palette.draw_bubble(self, _to_px(a.lerp(b, d / maxf(seg, 0.0001))), _scale * Board.R, _fly_color)
			return
		d -= seg
	Palette.draw_bubble(self, _to_px(_fly_path[-1]), _scale * Board.R, _fly_color)


# 발사대 = 아기 벌. 캐릭터가 있어야 지키고 싶은 마음이 생긴다(design-principles 1장)
func _draw_shooter() -> void:
	var at := _to_px(sess.shooter_pos())
	var rad := _scale * Board.R
	var dir := Vector2(sin(_aim_angle), -cos(_aim_angle))
	var flap := sin(_flash * (34.0 if _aiming else 16.0)) * 0.35
	Palette.draw_bee(self, at, rad, dir, flap)

	# 장전된 구슬 — 벌이 조준하는 방향으로 살짝 나와 있다
	Palette.draw_bubble(self, at + dir * rad * 1.30, rad * 0.92, sess.cur_color)

	# 다음 구슬 미리보기 — 옆에 작게
	var nx := at + Vector2(rad * 2.6, rad * 0.2)
	_text("다음", nx + Vector2(0, -rad * 0.95), 22, Palette.INK_DIM, HORIZONTAL_ALIGNMENT_CENTER)
	Palette.draw_bubble(self, nx, rad * 0.62, sess.next_color)


# ── HUD ──

func _draw_hud(vp: Vector2) -> void:
	draw_rect(Rect2(0, 0, vp.x, HUD_TOP - 12.0), Palette.PANEL)

	_text("점수", Vector2(SIDE_MARGIN, 40), 24, Palette.INK_DIM, HORIZONTAL_ALIGNMENT_LEFT)
	_text(str(sess.score), Vector2(SIDE_MARGIN, 84), 46, Palette.INK, HORIZONTAL_ALIGNMENT_LEFT)

	var quota := Difficulty.round_quota(sess.round_no)
	_text("라운드 %d" % (sess.round_no + 1), Vector2(vp.x * 0.5, 40), 24, Palette.INK_DIM, HORIZONTAL_ALIGNMENT_CENTER)
	_text("%d / %d" % [mini(sess.removed_in_round, quota), quota], Vector2(vp.x * 0.5, 84), 40, Palette.GOLD, HORIZONTAL_ALIGNMENT_CENTER)

	_text("최고", Vector2(vp.x - SIDE_MARGIN, 40), 24, Palette.INK_DIM, HORIZONTAL_ALIGNMENT_RIGHT)
	_text(str(maxi(Game.best_score, sess.score)), Vector2(vp.x - SIDE_MARGIN, 84), 46, Palette.INK_DIM, HORIZONTAL_ALIGNMENT_RIGHT)

	_draw_pollen(vp)


# 꽃가루 게이지 — 축2 그 자체라 화면에서 가장 크고 분명해야 한다
func _draw_pollen(vp: Vector2) -> void:
	var w := vp.x - SIDE_MARGIN * 2.0
	var h := 26.0
	var y := HUD_TOP + 4.0
	var ratio := clampf(sess.pollen / Difficulty.POLLEN_MAX, 0.0, 1.0)
	draw_rect(Rect2(SIDE_MARGIN, y, w, h), Color(0, 0, 0, 0.45))

	var col := Palette.GOLD
	if ratio < 0.22:
		# 마르기 직전엔 색과 점멸로 경고한다 — 여기가 벌집이 내려오는 순간이다
		col = Palette.DANGER.lerp(Palette.GOLD, 0.35 + 0.35 * sin(_flash * 11.0))
	elif ratio < 0.45:
		col = Palette.GOLD.lerp(Palette.DANGER, 0.4)
	draw_rect(Rect2(SIDE_MARGIN, y, w * ratio, h), col)
	draw_rect(Rect2(SIDE_MARGIN, y, w, h), Color(1, 1, 1, 0.12), false, 2.0)
	_text("꽃가루", Vector2(SIDE_MARGIN + 8.0, y + h - 5.0), 20, Color(0, 0, 0, 0.55), HORIZONTAL_ALIGNMENT_LEFT)


# ── 테스트 훅 ──
# 스모크·자동 검증이 이걸로 조작한다. 프로덕션에 남아도 무해하고, 없으면 시각 검증을 못 한다.

# 지금 판에서 가장 이득이 큰 각도를 찾아 쏜다 (봇의 판단을 그대로 씀)
func test_fire_best() -> void:
	if sess == null or sess.over or _flying:
		return
	var best_a := 0.0
	var best_gain := -INF
	for i in 41:
		var a: float = lerpf(-Session.MAX_ANGLE, Session.MAX_ANGLE, float(i) / 40.0)
		var pv := sess.preview(a)
		if pv["ok"] and float(pv["gain"]) > best_gain:
			best_gain = float(pv["gain"])
			best_a = a
	_aim_angle = best_a
	_fire()


func test_aim(angle: float) -> void:
	_aim_angle = clampf(angle, -Session.MAX_ANGLE, Session.MAX_ANGLE)
	_aiming = true
	queue_redraw()


func test_banner(round_done: int = 1, sweep: bool = false) -> void:
	_show_clear_banner(round_done, sweep)


func test_kill() -> void:
	if sess != null:
		sess.over = true
	_end()


# 상대 판 — 오른쪽 열에 작게. 누가 몰리고 있는지 한눈에 보여야 공격의 의미가 생긴다
func _draw_peers(vp: Vector2) -> void:
	if peers.is_empty():
		return
	var col_x := vp.x * (1.0 - PEER_COL_RATIO)
	var col_w := vp.x * PEER_COL_RATIO
	draw_rect(Rect2(col_x, HUD_TOP + 38.0, col_w, vp.y - HUD_TOP - 38.0), Color(0, 0, 0, 0.28))

	var pad := 8.0
	var cell_h := minf(190.0, (vp.y - BOARD_TOP) / float(peers.size()))
	var y := BOARD_TOP
	for p in peers:
		var mw := col_w - pad * 2.0
		var ms := mw / Board.W
		var name_col: Color = Palette.INK if int(p.get("team", 1)) == 0 else Palette.DANGER
		_text(str(p.get("name", "벌")), Vector2(col_x + pad, y + 18.0), 18, name_col, HORIZONTAL_ALIGNMENT_LEFT)
		var top := y + 26.0
		var b := str(p.get("board", ""))
		if b.length() >= Board.ROWS * Board.COLS:
			for r in Board.ROWS:
				for c in Board.COLS:
					var ch := b[r * Board.COLS + c]
					if ch == ".":
						continue
					var pos := Vector2(col_x + pad, top) + Board.cell_pos(r, c) * ms
					draw_circle(pos, ms * 0.92, Palette.bubble_color(int(ch)))
		if bool(p.get("dead", false)):
			draw_rect(Rect2(col_x + pad, top, mw, cell_h - 34.0), Color(0, 0, 0, 0.55))
			_text("탈락", Vector2(col_x + col_w * 0.5, top + (cell_h - 34.0) * 0.5), 22, Palette.DANGER, HORIZONTAL_ALIGNMENT_CENTER)
		_text("%d점" % int(p.get("score", 0)), Vector2(col_x + col_w - pad, y + 18.0), 16, Palette.INK_DIM, HORIZONTAL_ALIGNMENT_RIGHT)
		y += cell_h


func _text(s: String, pos: Vector2, size: int, col: Color, align: int) -> void:
	if _font == null:
		return
	var w := 460.0
	var p := pos
	match align:
		HORIZONTAL_ALIGNMENT_CENTER:
			p.x -= w * 0.5
		HORIZONTAL_ALIGNMENT_RIGHT:
			p.x -= w
	draw_string(_font, p, s, align, w, size, col)
