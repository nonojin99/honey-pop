# 벌집 판 — 순수 연산. 엔진 물리·렌더링·타이머를 일절 쓰지 않는다.
#
# 이 파일이 순수해야 하는 이유(harness.md 1번): 시뮬이 순수하면 수천 판을 헤드리스로 돌릴 수
# 있다. 봇 시뮬레이션은 이 board.gd 를 **게임과 똑같이** 쓴다 — 수식을 JS 로 옮겨 적는
# 방식(스킬 기본형)은 원본과 갈릴 수 있어서, 여기서는 원본 코드를 그대로 굴린다.
#
# ── 좌표계 ──
# 화면 픽셀이 아니라 unit 고정 좌표계다(dot-atelier 룰 2: 화면 크기가 판정에 영향 주면 공정성 버그).
# 구슬 반지름 R=1, 지름 D=2. 렌더러가 unit → 픽셀 배율만 곱한다.
#
# ── 격자 ──
# 모든 행이 COLS 칸으로 폭이 같고, 홀수 행만 오른쪽으로 반 칸(R) 밀린다.
#   cell_pos(r,c).x = R + c*D + (r&1)*R
#   cell_pos(r,c).y = R + r*ROW_H          (ROW_H = D*sin60 = R*√3)
# 폭이 균일해서 **한 줄 밀어내기가 무손실**이다 — 행마다 칸 수가 다른 8/7 배치는 밀 때
# 오른쪽 끝 구슬이 갈 곳을 잃는다(실제로 그 배치로 짜다 겪은 문제).
class_name Board
extends RefCounted

const EMPTY := -1

const R := 1.0
const D := 2.0
const ROW_H := 1.7320508075688772   # D * sin(60°) = R * √3

const COLS := Difficulty.COLS
const DEAD_ROW := Difficulty.DEAD_ROW
const ROWS := DEAD_ROW + 1

# 판 폭. 홀수 행이 반 칸 밀리므로 (2*COLS+1)*R 이다
const W := (2.0 * float(COLS) + 1.0) * R

var grid: Array = []          # grid[r][c] -> 색 인덱스, 없으면 EMPTY


func _init() -> void:
	clear()


func clear() -> void:
	grid = []
	for r in ROWS:
		var row: Array = []
		row.resize(COLS)
		row.fill(EMPTY)
		grid.append(row)


func duplicate_board() -> Board:
	var b := Board.new()
	for r in ROWS:
		for c in COLS:
			b.grid[r][c] = grid[r][c]
	return b


static func cell_pos(r: int, c: int) -> Vector2:
	return Vector2(R + float(c) * D + float(r & 1) * R, R + float(r) * ROW_H)


static func in_bounds(r: int, c: int) -> bool:
	return r >= 0 and r < ROWS and c >= 0 and c < COLS


func at(r: int, c: int) -> int:
	if not in_bounds(r, c):
		return EMPTY
	return grid[r][c]


func has(r: int, c: int) -> bool:
	return at(r, c) != EMPTY


func set_cell(r: int, c: int, v: int) -> void:
	if in_bounds(r, c):
		grid[r][c] = v


# 육각 이웃 6방향. 홀수 행이 오른쪽으로 밀려 있으므로 위/아래 대각의 열 오프셋이 행 짝수성에 따라 다르다
static func neighbors(r: int, c: int) -> Array:
	var odd := r & 1
	var out: Array = [
		Vector2i(r, c - 1), Vector2i(r, c + 1),
		Vector2i(r - 1, c - 1 + odd), Vector2i(r - 1, c + odd),
		Vector2i(r + 1, c - 1 + odd), Vector2i(r + 1, c + odd),
	]
	var res: Array = []
	for v in out:
		if in_bounds(v.x, v.y):
			res.append(v)
	return res


# ── 판 상태 질의 ──

func is_empty_board() -> bool:
	for r in ROWS:
		for c in COLS:
			if grid[r][c] != EMPTY:
				return false
	return true


func lowest_row() -> int:
	for r in range(ROWS - 1, -1, -1):
		for c in COLS:
			if grid[r][c] != EMPTY:
				return r
	return -1


func is_dead() -> bool:
	return lowest_row() >= DEAD_ROW


# 판에 남아 있는 색 목록.
# ★ 공정성 룰 1 — 다음 구슬은 반드시 이 목록 안에서만 뽑는다. 판에 없는 색을 주면
#   그 발은 구조적으로 매치 불가능하고, 그런 발이 연속되면 클리어 불가능 구간이 된다.
func colors_present() -> Array:
	var seen := {}
	for r in ROWS:
		for c in COLS:
			var v: int = grid[r][c]
			if v != EMPTY:
				seen[v] = true
	var out: Array = seen.keys()
	out.sort()
	return out


func count_bubbles() -> int:
	var n := 0
	for r in ROWS:
		for c in COLS:
			if grid[r][c] != EMPTY:
				n += 1
	return n


# ── 매치 / 낙하 ──

# (r,c) 에서 같은 색으로 이어진 덩어리 (BFS)
func same_color_group(r: int, c: int) -> Array:
	var color := at(r, c)
	if color == EMPTY:
		return []
	var seen := {Vector2i(r, c): true}
	var queue: Array = [Vector2i(r, c)]
	var out: Array = []
	while not queue.is_empty():
		var cur: Vector2i = queue.pop_back()
		out.append(cur)
		for nb in neighbors(cur.x, cur.y):
			if seen.has(nb):
				continue
			if at(nb.x, nb.y) == color:
				seen[nb] = true
				queue.append(nb)
	return out


# 천장(0행)에 이어지지 않은 구슬들 — 지지대를 잃었으므로 떨어진다.
# 이게 Puzzle Bobble 의 핵심 쾌감이자, 한 발로 판을 크게 되돌릴 수 있는 유일한 수단이다.
func floating_cells() -> Array:
	var anchored := {}
	var queue: Array = []
	for c in COLS:
		if grid[0][c] != EMPTY:
			var v := Vector2i(0, c)
			anchored[v] = true
			queue.append(v)
	while not queue.is_empty():
		var cur: Vector2i = queue.pop_back()
		for nb in neighbors(cur.x, cur.y):
			if anchored.has(nb):
				continue
			if at(nb.x, nb.y) != EMPTY:
				anchored[nb] = true
				queue.append(nb)
	var out: Array = []
	for r in ROWS:
		for c in COLS:
			if grid[r][c] != EMPTY and not anchored.has(Vector2i(r, c)):
				out.append(Vector2i(r, c))
	return out


# 구슬을 놓은 뒤의 결과를 한 번에 처리한다.
# 반환: {popped: Array[Vector2i], dropped: Array[Vector2i]}
func resolve_place(r: int, c: int) -> Dictionary:
	var group := same_color_group(r, c)
	if group.size() < 3:
		return {"popped": [], "dropped": []}
	for v in group:
		grid[v.x][v.y] = EMPTY
	var dropped := floating_cells()
	for v in dropped:
		grid[v.x][v.y] = EMPTY
	return {"popped": group, "dropped": dropped}


# 한 줄 밀어내기. 새 줄이 천장에 생기고 전체가 한 칸 내려온다.
# 폭이 균일해서 손실이 없다. 밀린 뒤 각 행의 짝수성이 뒤집혀 반 칸씩 어긋나는 것도
# 원작과 같은 거동이다.
func push_row(new_row: Array) -> void:
	grid.pop_back()
	var row: Array = []
	row.resize(COLS)
	for c in COLS:
		row[c] = new_row[c] if c < new_row.size() else EMPTY
	grid.push_front(row)


# ── 발사 궤적 ──
# 순수 기하 계산. 엔진 물리를 쓰지 않는 이유는 재현성이다 — 같은 각도는 항상 같은 결과여야
# 봇 시뮬과 실제 플레이가 같은 게임이 된다.
#
# from: 발사 위치(unit), dir: 정규화된 방향(위로 쏘므로 y 음수)
# 반환: {hit: bool, r: int, c: int, path: Array[Vector2]}  — hit=false 면 놓을 자리가 없다
func trace_shot(from: Vector2, dir: Vector2, step: float = 0.12) -> Dictionary:
	var p := from
	var d := dir.normalized()
	var path: Array = [p]
	var guard := 0
	while guard < 4000:
		guard += 1
		p += d * step
		# 좌우 벽 반사 — 축1(뱅크샷)의 근거
		if p.x < R:
			p.x = R + (R - p.x)
			d.x = -d.x
			path.append(p)
		elif p.x > W - R:
			p.x = (W - R) - (p.x - (W - R))
			d.x = -d.x
			path.append(p)
		# 천장
		if p.y <= R:
			p.y = R
			path.append(p)
			return _snap(p, path)
		# 기존 구슬과 충돌
		if _overlaps(p):
			path.append(p)
			return _snap(p, path)
		# 발사대는 판보다 아래에 있다. 종료 기준을 판 높이로 잡으면 첫 스텝에서 바로 끊긴다
		# (실제로 그 버그로 모든 각도가 "놓을 수 없음"이 됐다). 기준은 발사 지점이다.
		if p.y > from.y + R:
			break
		if path.size() < 512 and guard % 4 == 0:
			path.append(p)
	return {"hit": false, "r": -1, "c": -1, "path": path}


func _overlaps(p: Vector2) -> bool:
	# 주변 3행 × 3열만 본다. 전 칸 순회는 봇 시뮬에서 수십만 발을 쏠 때 그대로 실행 시간이 된다
	var r0 := maxi(0, int((p.y - R) / ROW_H) - 1)
	var r1 := mini(ROWS - 1, r0 + 3)
	for r in range(r0, r1 + 1):
		var cc := int(round((p.x - R - float(r & 1) * R) / D))
		for c in range(maxi(0, cc - 1), mini(COLS - 1, cc + 1) + 1):
			if grid[r][c] == EMPTY:
				continue
			if p.distance_squared_to(cell_pos(r, c)) < (D * D) * 0.98:
				return true
	return false


# 멈춘 위치에서 가장 가까운 "놓을 수 있는" 빈 칸.
# 놓을 수 있다 = 비어 있고, 0행이거나 이웃에 구슬이 있다.
func _snap(p: Vector2, path: Array) -> Dictionary:
	var best := Vector2i(-1, -1)
	var best_d := INF
	var r0 := maxi(0, int((p.y - R) / ROW_H) - 2)
	var r1 := mini(ROWS - 1, r0 + 5)
	for r in range(r0, r1 + 1):
		var cc := int(round((p.x - R - float(r & 1) * R) / D))
		for c in range(maxi(0, cc - 2), mini(COLS - 1, cc + 2) + 1):
			if grid[r][c] != EMPTY:
				continue
			if r != 0 and not _has_occupied_neighbor(r, c):
				continue
			var dd := p.distance_squared_to(cell_pos(r, c))
			if dd < best_d:
				best_d = dd
				best = Vector2i(r, c)
	if best.x < 0:
		return {"hit": false, "r": -1, "c": -1, "path": path}
	return {"hit": true, "r": best.x, "c": best.y, "path": path}


func _has_occupied_neighbor(r: int, c: int) -> bool:
	for nb in neighbors(r, c):
		if grid[nb.x][nb.y] != EMPTY:
			return true
	return false
