# 라운드 생성 + 다음 구슬 뽑기 — 공정성이 여기서 결정된다.
#
# 공정성 룰 (verification.md 2장: "운이 가장 나쁜 플레이어에게도 물리적으로 가능한가?")
#   1. 다음 구슬 색은 반드시 **판에 남아 있는 색** 중에서만 뽑는다.
#      판에 없는 색을 주면 그 발은 구조적으로 매치 불가능하다.
#   2. 초기 배치의 모든 색은 **3개 이상** 존재한다. 2개짜리 색이 섞이면 그 색은
#      영원히 못 지우는 찌꺼기가 되어 판이 서서히 막힌다.
#   3. 밀어내기로 들어오는 새 줄도 같은 규칙을 따른다.
class_name Level
extends RefCounted


# 라운드 n 의 시작 판
static func build(n: int, rng: Rng) -> Board:
	var b := Board.new()
	var ncol := Difficulty.colors(n)
	var rows := Difficulty.start_rows(n)
	for r in rows:
		for c in Board.COLS:
			b.grid[r][c] = rng.next_int(ncol)
	_ensure_min_three(b, ncol, rng)
	_ensure_solvable(b, ncol, rng)
	return b


# 공정성 룰 4 — "첫 수부터 막힌 판"을 없앤다.
#
# 검증에서 실제로 600판 중 2판이 어떤 색·각도로도 3개 매치가 안 나는 판이었다. 그런 판을
# 뽑은 플레이어는 시작하자마자 꽃가루만 잃는다 — 실력이 아니라 운으로 지는 구간이다.
#
# 보장 방식: 최하단 행 바로 아래 행(= 완전히 비어 있어 아래에서 직선으로 닿는 행)의 어떤 칸이
# 위쪽 이웃 2개를 같은 색으로 가지면, 그 색을 그 칸에 넣는 순간 3개 매치가 확정된다.
# 그런 칸이 없으면 하나 만들어 준다.
static func _ensure_solvable(b: Board, ncol: int, rng: Rng) -> void:
	if _reachable_match_exists(b):
		return
	var low := b.lowest_row()
	if low < 0 or low + 1 >= Board.DEAD_ROW:
		return
	var r := low + 1
	var odd := r & 1
	for c in Board.COLS:
		if b.grid[r][c] != Board.EMPTY:
			continue
		var u1 := Vector2i(r - 1, c - 1 + odd)
		var u2 := Vector2i(r - 1, c + odd)
		if not Board.in_bounds(u1.x, u1.y) or not Board.in_bounds(u2.x, u2.y):
			continue
		if b.grid[u1.x][u1.y] == Board.EMPTY or b.grid[u2.x][u2.y] == Board.EMPTY:
			continue
		var color: int = b.grid[u1.x][u1.y]
		b.grid[u2.x][u2.y] = color
		# 색을 하나 덮었으니 "3개 미만 색" 규칙이 깨졌을 수 있다 — 다시 세워 준다.
		# (여기서 만든 짝은 같은 색을 늘리는 방향이라 이 보정이 짝을 되돌리지 않는다)
		_ensure_min_three(b, ncol, rng)
		return


# 아래에서 확실히 닿는 행(최하단+1)에 "같은 색 이웃 2개"를 가진 빈 칸이 있는가
static func _reachable_match_exists(b: Board) -> bool:
	var low := b.lowest_row()
	if low < 0:
		return true
	var r := low + 1
	if r >= Board.ROWS:
		return false
	for c in Board.COLS:
		if b.grid[r][c] != Board.EMPTY:
			continue
		var tally := {}
		for nb in Board.neighbors(r, c):
			var v: int = b.grid[nb.x][nb.y]
			if v != Board.EMPTY:
				tally[v] = int(tally.get(v, 0)) + 1
				if int(tally[v]) >= 2:
					return true
	return false


# 공정성 룰 2 — 3개 미만인 색을 없애서 "못 지우는 찌꺼기"를 만들지 않는다.
# 부족한 색은 가장 흔한 색의 칸을 빼앗아 3개를 채우고, 그래도 안 되면 그 색을 통째로 치환한다.
static func _ensure_min_three(b: Board, ncol: int, rng: Rng) -> void:
	for _pass in 8:
		var counts := _color_counts(b, ncol)
		var lacking: Array = []
		for v in ncol:
			if int(counts[v]) > 0 and int(counts[v]) < 3:
				lacking.append(v)
		if lacking.is_empty():
			return
		for v in lacking:
			var donor := _most_common(counts, v)
			if donor < 0 or int(counts[donor]) - (3 - int(counts[v])) < 3:
				# 기부할 색이 없으면 그 색을 아예 지운다(가장 흔한 색으로 치환)
				var repl := _most_common(counts, v)
				if repl < 0:
					return
				_replace_color(b, v, repl)
				break
			var need: int = 3 - int(counts[v])
			var cells := _cells_of(b, donor)
			for i in mini(need, cells.size()):
				var cell: Vector2i = cells[rng.next_int(cells.size())]
				b.grid[cell.x][cell.y] = v
				cells.erase(cell)
			break


static func _color_counts(b: Board, ncol: int) -> Array:
	var counts: Array = []
	counts.resize(ncol)
	counts.fill(0)
	for r in Board.ROWS:
		for c in Board.COLS:
			var v: int = b.grid[r][c]
			if v >= 0 and v < ncol:
				counts[v] += 1
	return counts


static func _most_common(counts: Array, exclude: int) -> int:
	var best := -1
	var best_n := 0
	for v in counts.size():
		if v == exclude:
			continue
		if counts[v] > best_n:
			best_n = counts[v]
			best = v
	return best


static func _cells_of(b: Board, color: int) -> Array:
	var out: Array = []
	for r in Board.ROWS:
		for c in Board.COLS:
			if b.grid[r][c] == color:
				out.append(Vector2i(r, c))
	return out


static func _replace_color(b: Board, from_color: int, to_color: int) -> void:
	for r in Board.ROWS:
		for c in Board.COLS:
			if b.grid[r][c] == from_color:
				b.grid[r][c] = to_color


# 공정성 룰 1 — 판에 있는 색 중에서만 뽑는다. 판이 비었으면 -1(쏠 필요 없음)
static func next_color(b: Board, rng: Rng) -> int:
	var present := b.colors_present()
	if present.is_empty():
		return -1
	return present[rng.next_int(present.size())]


# 밀어내기로 들어올 새 줄. 판에 있는 색으로만 채워 룰 1 을 깨지 않는다
static func new_row(b: Board, n: int, rng: Rng) -> Array:
	var present := b.colors_present()
	if present.is_empty():
		var ncol := Difficulty.colors(n)
		present = []
		for v in ncol:
			present.append(v)
	var row: Array = []
	row.resize(Board.COLS)
	for c in Board.COLS:
		row[c] = present[rng.next_int(present.size())]
	return row
