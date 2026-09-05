# 한 판 — 순수 게임 엔진. 렌더러도 타이머도 없다.
#
# 실제 플레이와 봇 시뮬이 **같은 이 파일**을 굴린다. 스킬 기본형은 난이도 수식을 JS 시뮬로
# 따로 옮겨 적지만, 그러면 원본과 갈릴 수 있다. 여기서는 원본을 그대로 돌린다.
#
# 조작 단위는 "한 발" = (각도, 조준에 쓴 시간). 조준 시간이 축2(꽃가루)를 먹기 때문에
# 이 한 쌍이 곧 2축 의사결정 그 자체다.
class_name Session
extends RefCounted

const SCORE_POP := 10
# 낙하는 개수에 대해 초선형이다 — 한 발로 큰 덩어리를 끊는 뱅크샷이 축1 정밀도의 최고 보상이고,
# 여기가 실력이 점수로 벌어지는 유일한 지점이다(선형으로 뒀더니 고수/중수가 1.14배로 붙었다).
const SCORE_DROP := 12
const DROP_EXP := 1.45
const SCORE_ROUND := 200
const SCORE_ROUND_STEP := 120
const SCORE_SWEEP := 300        # 할당량이 아니라 판을 진짜 다 비웠을 때의 추가 보상
const SCORE_SWEEP_STEP := 150

const MAX_ANGLE := deg_to_rad(80.0)   # 옆·아래로는 못 쏜다

var board: Board
var rng: Rng
var round_no := 0
var score := 0
var pollen := Difficulty.POLLEN_MAX
var shots_left := 0
var cur_color := 0
var next_color := 0
var over := false
var shots_fired := 0
var shots_in_round := 0         # 라운드 내부 압박 상승의 입력값
var removed_in_round := 0       # 이 라운드에서 없앤 구슬 수 (라운드 진행 조건)
var swept := 0                  # 판을 완전히 비운 횟수
var pending_attack := 0         # 대결 모드: 상대가 보낸, 다음 발에 내려올 방해 구슬 수
var descends := 0               # 벌집이 내려온 총 횟수 (압박 지표)
var dry_events := 0             # 게이지 고갈 횟수 (축2 실패 지표)


func _init(seed_value: int = 12345, start_round: int = 0) -> void:
	rng = Rng.new(seed_value)
	round_no = start_round
	_begin_round()


func shooter_pos() -> Vector2:
	return Vector2(Board.W * 0.5, float(Board.ROWS) * Board.ROW_H + 2.0)


func _begin_round() -> void:
	board = Level.build(round_no, rng)
	shots_left = Difficulty.shots_per_descend(round_no)
	shots_in_round = 0
	removed_in_round = 0
	pollen = Difficulty.POLLEN_MAX
	cur_color = Level.next_color(board, rng)
	next_color = Level.next_color(board, rng)


# 다음 구슬로 넘긴다. 공정성 룰 1 은 여기서도 지켜진다 — 판이 바뀌었으면 색을 다시 뽑는다
func _advance_queue() -> void:
	cur_color = next_color
	var present := board.colors_present()
	if cur_color == -1 or (not present.is_empty() and not present.has(cur_color)):
		cur_color = Level.next_color(board, rng)
	next_color = Level.next_color(board, rng)


func _drain(amount: float) -> void:
	pollen -= amount
	while pollen <= 0.0 and not over:
		# 고갈은 즉사가 아니라 "한 줄 하강 + 재충전"이다.
		# 즉사로 만들면 축2 가 도박이 되어 2축 구조가 무너진다(harness.md 의 헛디딤 교훈).
		dry_events += 1
		pollen += Difficulty.POLLEN_MAX * Difficulty.DRY_REFILL
		_descend()


# 실시간 플레이용 — 매 프레임 흘러간 시간만큼 꽃가루를 깎는다.
# 봇 시뮬은 fire(각도, 조준시간) 으로 같은 계산을 한 번에 한다. 둘이 같은 _drain 을 타므로
# "시뮬에서 잰 난이도"와 "손으로 겪는 난이도"가 같은 수식 위에 있다.
func tick(dt: float) -> void:
	if over or dt <= 0.0:
		return
	_drain(Difficulty.drain_rate(round_no, shots_in_round) * dt)


func _descend() -> void:
	board.push_row(Level.new_row(board, round_no, rng))
	descends += 1
	if board.is_dead():
		over = true


# 한 발. angle 은 라디안(0=수직 위), aim_time 은 조준에 쓴 초.
# 반환: {ok, popped, dropped, cleared, dry, dead, r, c, path}
func fire(angle: float, aim_time: float) -> Dictionary:
	if over:
		return {"ok": false, "popped": 0, "dropped": 0, "cleared": false, "dead": true, "path": []}

	# ── 축2: 조준한 시간만큼 꽃가루가 준다 ──
	var before_dry := dry_events
	_drain(Difficulty.drain_rate(round_no, shots_in_round) * maxf(0.0, aim_time))
	if over:
		return {"ok": false, "popped": 0, "dropped": 0, "cleared": false, "dry": true, "dead": true, "path": []}

	# ── 축1: 궤적 ──
	var a := clampf(angle, -MAX_ANGLE, MAX_ANGLE)
	var dir := Vector2(sin(a), -cos(a))
	var shot := board.trace_shot(shooter_pos(), dir)
	shots_fired += 1
	shots_in_round += 1

	if not shot["hit"]:
		# 놓을 자리를 못 찾은 발 — 빗나감으로 친다
		pollen -= Difficulty.MISS_COST
		_after_shot()
		return {"ok": false, "popped": 0, "dropped": 0, "cleared": false,
			"dry": dry_events > before_dry, "dead": over, "path": shot["path"]}

	var r: int = shot["r"]
	var c: int = shot["c"]
	board.set_cell(r, c, cur_color)
	var res := board.resolve_place(r, c)
	var popped: int = res["popped"].size()
	var dropped: int = res["dropped"].size()

	if popped > 0:
		score += popped * SCORE_POP + drop_score(dropped)
		removed_in_round += popped + dropped
		pollen = minf(Difficulty.POLLEN_MAX, pollen + Difficulty.recover(popped, dropped))
	else:
		pollen -= Difficulty.MISS_COST

	# 라운드 진행: 할당량을 채웠거나 판을 다 비웠거나
	var sweep := board.is_empty_board()
	if sweep or removed_in_round >= Difficulty.round_quota(round_no):
		score += SCORE_ROUND + SCORE_ROUND_STEP * round_no
		if sweep:
			swept += 1
			score += SCORE_SWEEP + SCORE_SWEEP_STEP * round_no
		round_no += 1
		_begin_round()
		return {"ok": true, "popped": popped, "dropped": dropped, "cleared": true,
			"sweep": sweep, "dry": dry_events > before_dry, "dead": false,
			"r": r, "c": c, "path": shot["path"]}

	_after_shot()
	if pollen <= 0.0:
		_drain(0.0)
	return {"ok": true, "popped": popped, "dropped": dropped, "cleared": false,
		"dry": dry_events > before_dry, "dead": over, "r": r, "c": c, "path": shot["path"]}


# ── 대결 모드 ──
# 각자 자기 판만 돌리고 공격 수치만 주고받는다. 판 전체를 락스텝으로 맞출 필요가 없어서
# 네트워크가 "정수 하나"로 끝난다 — 지연이나 패킷 유실이 판정을 깨뜨리지 못한다.

# 이번 한 발이 상대에게 보내는 공격량. 큰 낙하를 만들수록 크게 보낸다(축1 정밀도의 대결판 보상)
static func attack_of(popped: int, dropped: int) -> int:
	if popped <= 0:
		return 0
	return dropped + maxi(0, popped - 3)


func receive_attack(n: int) -> void:
	pending_attack += maxi(0, n)


# 받아 둔 공격을 실제 방해 줄로 내린다. 한 줄을 다 채우지 않고 받은 만큼만 흩뿌린다
func _apply_pending() -> void:
	if pending_attack <= 0 or over:
		return
	var k := mini(Board.COLS, pending_attack)
	pending_attack -= k
	var present := board.colors_present()
	if present.is_empty():
		present = [0]
	var row: Array = []
	row.resize(Board.COLS)
	row.fill(Board.EMPTY)
	var cols: Array = []
	for c in Board.COLS:
		cols.append(c)
	for i in k:
		var pick := rng.next_int(cols.size())
		row[cols[pick]] = present[rng.next_int(present.size())]
		cols.remove_at(pick)
	board.push_row(row)
	descends += 1
	if board.is_dead():
		over = true


# 판 상태를 짧은 문자열로 — 상대 화면에 내 판을 보여 주기 위한 것. 117칸이라 한 줄이면 끝난다
func encode_board() -> String:
	var out := ""
	for r in Board.ROWS:
		for c in Board.COLS:
			var v: int = board.grid[r][c]
			out += "." if v == Board.EMPTY else str(v)
	return out


# 낙하 점수 — 개수에 대해 초선형
static func drop_score(dropped: int) -> int:
	if dropped <= 0:
		return 0
	return int(round(float(SCORE_DROP) * pow(float(dropped), DROP_EXP)))


func _after_shot() -> void:
	_apply_pending()
	if over:
		return
	_advance_queue()
	shots_left -= 1
	if shots_left <= 0:
		shots_left = Difficulty.shots_per_descend(round_no)
		_descend()
	if board.is_dead():
		over = true


# ── 봇/AI 보조: 이 각도로 쐈을 때의 결과를 미리 재 본다(판을 복제해서) ──
# 실제 플레이에는 안 쓴다. 시뮬 전용이라 여기 두는 게 맞다 — 게임과 같은 규칙으로 평가해야
# 봇의 판단이 실제 판단과 같은 게임을 대상으로 한 것이 된다.
func preview(angle: float) -> Dictionary:
	var a := clampf(angle, -MAX_ANGLE, MAX_ANGLE)
	var dir := Vector2(sin(a), -cos(a))
	var shot := board.trace_shot(shooter_pos(), dir, 0.2)
	if not shot["hit"]:
		return {"ok": false, "gain": -1.0, "r": -1, "c": -1}
	var sim := board.duplicate_board()
	sim.set_cell(shot["r"], shot["c"], cur_color)
	var res := sim.resolve_place(shot["r"], shot["c"])
	var popped: int = res["popped"].size()
	var dropped: int = res["dropped"].size()
	var gain := float(popped) + 2.5 * float(dropped)
	if popped == 0:
		# 못 터뜨린 발은 판을 키운다. 낮은 자리에 붙을수록 더 나쁘다
		gain = -0.5 - 0.25 * float(shot["r"])
	return {"ok": true, "gain": gain, "popped": popped, "dropped": dropped,
		"r": shot["r"], "c": shot["c"]}
