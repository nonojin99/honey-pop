# 수학적 공정성 검증 (배포 전 필수 룰 — verification.md 2장)
#
#   godot --headless --path . --script res://tools/verify_fairness.gd
#
# 묻는 것: **"운이 가장 나쁜 플레이어에게도 물리적으로 가능한가?"**
# 하나라도 어긋나면 exit 1 로 실패시킨다. 통과 전에는 배포 금지.
#
# 검사 항목
#   A. 곡선 형태   — 모든 난이도 파라미터가 단조이고 하한으로 수렴하는가 (플래토 없음)
#   B. 조준 하한   — 최소 매치(3개)만 성공시키는 플레이어의 조준 여유 ≥ 인간 하한 0.25초
#   C. 도입부 관대 — 라운드 0 의 여유가 하한의 3~4배 (design-principles 4장)
#   D. 판 생성     — 모든 색이 3개 이상 (못 지우는 찌꺼기 색 금지)
#   E. 색 공급     — 다음 구슬이 항상 판에 있는 색 (구조적 매치 불가능 발 금지)
#   F. 즉사 금지   — 라운드 시작 판이 이미 데드라인에 닿아 있지 않은가
#   G. 통과 갭     — 어느 판에서든 구슬을 놓을 수 있는 각도가 존재하는가
#   H. 회복 가능성 — 어느 판에서든 3개 매치가 나는 각도가 존재하는가 (막힌 판 금지)
extends SceneTree

# Difficulty / Board / Level / Session / Rng 은 class_name 으로 전역 등록돼 있다.
# preload 상수로 다시 잡으면 "hides a global script class" 로 컴파일이 막힌다.

const MAX_ROUND := 80          # 이 게임의 현실적 상한을 훨씬 넘는 구간까지 본다
const HUMAN_AIM_FLOOR := 0.25  # 사람이 조준해 쏘는 데 필요한 최소 시간(초)
const SEEDS := 60              # 판 생성 검사 시드 수
const ANGLE_SAMPLES := 91      # 각도 스캔 해상도 (-80°~+80°)

var _fails: Array = []
var _stats := {"levels": 0, "cells": 0, "shots_scanned": 0}


func _initialize() -> void:
	_check_curves()
	_check_aim_floor()
	_check_intro_generosity()
	_check_levels()
	_finish()


# ── A. 곡선 형태 ──
func _check_curves() -> void:
	var prev_t := INF
	var prev_s := INF
	var prev_c := -1
	var prev_r := -1
	for n in MAX_ROUND + 1:
		var t := Difficulty.t_budget(n)
		var s := float(Difficulty.shots_per_descend(n))
		var c := Difficulty.colors(n)
		var r := Difficulty.start_rows(n)

		if t > prev_t + 1e-9:
			_fail("A", "t_budget 이 n=%d 에서 증가했다 (%.4f → %.4f)" % [n, prev_t, t])
		if t < Difficulty.T_BUDGET_MIN - 1e-9:
			_fail("A", "t_budget 이 n=%d 에서 하한 아래로 내려갔다 (%.4f < %.4f)" % [n, t, Difficulty.T_BUDGET_MIN])
		if s > prev_s + 1e-9:
			_fail("A", "shots_per_descend 가 n=%d 에서 증가했다" % n)
		if s < Difficulty.SHOTS_MIN - 1e-9:
			_fail("A", "shots_per_descend 가 n=%d 에서 하한 아래로 (%.2f)" % [n, s])
		if c < prev_c:
			_fail("A", "colors 가 n=%d 에서 감소했다" % n)
		if c > Difficulty.COLORS_MAX:
			_fail("A", "colors 가 n=%d 에서 상한 초과 (%d)" % [n, c])
		if r < prev_r:
			_fail("A", "start_rows 가 n=%d 에서 감소했다" % n)
		if r > Difficulty.ROWS_MAX:
			_fail("A", "start_rows 가 n=%d 에서 상한 초과 (%d)" % [n, r])
		# 시작 줄이 데드라인을 이미 침범하면 그 라운드는 시작하자마자 게임오버다
		if r >= Difficulty.DEAD_ROW:
			_fail("A", "start_rows(%d)=%d 가 DEAD_ROW(%d) 이상이다" % [n, r, Difficulty.DEAD_ROW])

		prev_t = t
		prev_s = s
		prev_c = c
		prev_r = r

	# 하한으로 실제로 수렴하는가 (상수 상한을 두면 여기서 걸린다)
	var tail := Difficulty.t_budget(MAX_ROUND)
	if tail > Difficulty.T_BUDGET_MIN * 1.05:
		_fail("A", "t_budget 이 n=%d 에서도 하한의 1.05배 위다 (%.3f) — 수렴이 너무 느리다" % [MAX_ROUND, tail])


# ── B. 조준 하한 ──
# 최소 매치(3개)만 성공시키는 플레이어가 한 발에 쓸 수 있는 조준 시간.
# 이 값이 사람의 조준 하한보다 작으면 그 라운드는 물리적으로 유지 불가능하다.
func _check_aim_floor() -> void:
	for n in MAX_ROUND + 1:
		var w := Difficulty.min_aim_window(n)
		if w < HUMAN_AIM_FLOOR:
			_fail("B", "n=%d 에서 최소 매치 조준 여유 %.3fs < 인간 하한 %.2fs — 클리어 불가능 구간" % [n, w, HUMAN_AIM_FLOOR])
	# 점근값도 압박 상승 최대치를 반영해야 실제 하한과 같은 수를 말한다
	var limit := Difficulty.RECOVER_PER_POP * 3.0 / (Difficulty.POLLEN_MAX / Difficulty.T_BUDGET_MIN * Difficulty.ESCALATE_MAX)
	print("B. 조준 여유: n=0 %.2fs → n=%d %.2fs → 점근 %.2fs (인간 하한 %.2fs, 여유 %.1f배)"
		% [Difficulty.min_aim_window(0), MAX_ROUND, Difficulty.min_aim_window(MAX_ROUND), limit, HUMAN_AIM_FLOOR, limit / HUMAN_AIM_FLOOR])


# ── C. 도입부 관대함 ──
func _check_intro_generosity() -> void:
	var ratio := Difficulty.T_BUDGET_0 / Difficulty.T_BUDGET_MIN
	if ratio < 3.0 or ratio > 4.5:
		_fail("C", "도입부 관대함이 하한의 %.2f배 — 권장 3~4배를 벗어났다" % ratio)
	print("C. 도입부 관대함 %.2f배 (T_BUDGET %.1fs → %.1fs)" % [ratio, Difficulty.T_BUDGET_0, Difficulty.T_BUDGET_MIN])


# ── D~H. 실제 생성되는 판을 훑는다 ──
func _check_levels() -> void:
	for i in SEEDS:
		var seed_value := 1000 + i * 7919
		var rng := Rng.new(seed_value)
		# 라운드를 넓게 훑되 시드마다 다른 구간을 본다 (전 구간 커버 + 비용 절감)
		for n in [0, 1, 2, 3, 5, 8, 12, 18, 25, 40]:
			var b := Level.build(n, Rng.new(seed_value + n * 131))
			_check_one_level(n, b, rng, seed_value)


func _check_one_level(n: int, b: Board, rng, seed_value: int) -> void:
	_stats["levels"] += 1
	_stats["cells"] += b.count_bubbles()

	# D. 모든 색이 3개 이상
	var counts := {}
	for r in Board.ROWS:
		for c in Board.COLS:
			var v: int = b.grid[r][c]
			if v != Board.EMPTY:
				counts[v] = int(counts.get(v, 0)) + 1
	for v in counts.keys():
		if int(counts[v]) < 3:
			_fail("D", "seed=%d n=%d: 색 %d 이 %d개뿐 — 영원히 못 지우는 찌꺼기가 된다" % [seed_value, n, v, counts[v]])

	# E. 다음 구슬이 항상 판에 있는 색
	var present := b.colors_present()
	for _k in 30:
		var col: int = Level.next_color(b, rng)
		if col == -1:
			_fail("E", "seed=%d n=%d: 판이 비지 않았는데 뽑을 색이 없다" % [seed_value, n])
			break
		if not present.has(col):
			_fail("E", "seed=%d n=%d: 판에 없는 색 %d 을 뽑았다 — 구조적 매치 불가능 발" % [seed_value, n, col])
			break

	# F. 시작하자마자 게임오버가 아닌가
	if b.is_dead():
		_fail("F", "seed=%d n=%d: 시작 판이 이미 데드라인에 닿아 있다 (lowest_row=%d)" % [seed_value, n, b.lowest_row()])

	# G/H. 각도 스캔 — 놓을 수 있는가 / 3개 매치가 나는가.
	# "존재하는가"를 묻는 검사이므로 찾는 즉시 끊는다 (전수 스캔은 판×색×각도로 비용이 폭발한다).
	var sess = _fake_session(b, n, present[0] if not present.is_empty() else 0)
	var landed := 0
	var best_pop := 0
	for color in present:
		sess.cur_color = color
		for i in ANGLE_SAMPLES:
			var a: float = lerpf(-Session.MAX_ANGLE, Session.MAX_ANGLE, float(i) / float(ANGLE_SAMPLES - 1))
			var pv: Dictionary = sess.preview(a)
			_stats["shots_scanned"] += 1
			if pv["ok"]:
				landed += 1
				best_pop = maxi(best_pop, int(pv.get("popped", 0)))
				if best_pop >= 3:
					break
		if best_pop >= 3:
			break
	if landed == 0:
		_fail("G", "seed=%d n=%d: 어떤 각도로도 구슬을 놓을 수 없다 — 통과 갭 없음" % [seed_value, n])
	if best_pop < 3:
		_fail("H", "seed=%d n=%d: 어떤 색·각도로도 3개 매치가 안 난다 — 막힌 판 (최대 %d개)" % [seed_value, n, best_pop])


# preview() 를 쓰기 위한 최소 세션. 판과 현재 색만 갈아끼운다
func _fake_session(b: Board, n: int, color: int):
	var s = Session.new(1, n)
	s.board = b
	s.cur_color = color
	return s


func _fail(scope: String, msg: String) -> void:
	if _fails.size() < 30:
		_fails.append("[%s] %s" % [scope, msg])
	elif _fails.size() == 30:
		_fails.append("… (이하 생략)")


func _finish() -> void:
	print("판 %d개 / 구슬 %d개 / 각도 %d회 스캔"
		% [_stats["levels"], _stats["cells"], _stats["shots_scanned"]])
	# ★ 거짓 PASS 방지 — 스크립트 오류로 검사가 통째로 건너뛰어도 _fails 는 비어 있다.
	#   실제로 level.gd 컴파일 실패 때 D~H 를 하나도 안 돌고 PASS 가 찍혔다.
	#   "검사가 실제로 돌았는가"를 검사 항목으로 승격시킨다.
	var expected := SEEDS * 10
	if _stats["levels"] < expected:
		_fail("!", "판 검사가 %d/%d 만 돌았다 — 검증이 건너뛰어졌다 (스크립트 오류 의심)" % [_stats["levels"], expected])
	if _stats["shots_scanned"] <= 0:
		_fail("!", "각도 스캔이 한 번도 안 돌았다 — G/H 미검증")
	if _fails.is_empty():
		print("PASS — 전 구간(라운드 0~%d)에서 클리어 불가능 상태 없음" % MAX_ROUND)
		quit(0)
	else:
		for f in _fails:
			print(f)
		print("FAIL — %d 건" % _fails.size())
		quit(1)
