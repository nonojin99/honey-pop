# 대결 모드 — 1 VS 1 / 2 VS 2, Supabase Realtime 위에서.
#
# ── 왜 이렇게 단순한가 ──
# session.gd 가 순수 연산이라 **각자 자기 판만 돌린다**. 주고받는 건 공격량(정수 하나)과
# 보여 주기용 판 문자열뿐이다. 락스텝 동기화가 없으니 지연·패킷 유실이 판정을 깨뜨릴 수 없고,
# 발당 대역폭이 수백 바이트로 끝난다.
#
# ── 매칭 ──
# 전용 매칭 서버가 없다. 대신 **모드별 로비 채널**에 모여 서로를 발견하고, 모인 사람들의
# id 를 정렬해 앞에서부터 필요한 인원만큼 끊는 방식으로 방을 만든다. 같은 목록을 본 사람은
# 같은 방 이름을 계산하므로 합의가 필요 없다.
#
#   로비 topic   realtime:honey-pop:lobby-<mode>
#   방  topic    realtime:honey-pop:m-<방코드>
#
# ★ 목록이 사람마다 다른 순간이 있다(입장 시차). 그래서 **정착 대기**를 둔다 —
#   구성원이 마지막으로 바뀐 뒤 SETTLE 초 동안 조용해야 방을 만든다.
extends Node

signal state_changed(state: String, detail: String)
signal match_started(team: int, members: Array)
signal peer_board(key: String, board: String, score: int, dead: bool)
signal attacked(amount: int)
signal match_over(win: bool, detail: String)

const SETTLE := 2.0             # 구성원이 조용해진 뒤 이만큼 기다렸다가 방을 만든다
const LOBBY_TIMEOUT := 45.0
const SYNC_HZ := 3.0

enum { IDLE, SEEKING, MATCHED, PLAYING, DONE }

var state := IDLE
var mode_size := 2              # 2 = 1v1, 4 = 2v2
var my_team := 0
var members: Array = []         # 이 판의 참가자 키 (정렬됨)
var teams: Dictionary = {}      # key -> team(0/1)
var alive: Dictionary = {}      # key -> bool
var seed_value := 0

var _settle := 0.0
var _elapsed := 0.0
var _sync := 0.0
var _room := ""
var _last_seen: Dictionary = {} # 로비에서 본 사람들 key -> name
var lobby_tag := ""            # 통합 테스트용 로비 분리 — 공용 로비에서 테스트하면 실제 플레이어와 섞인다


func _ready() -> void:
	set_process(true)
	Net.msg.connect(_on_msg)
	Net.joined.connect(_on_joined)
	Net.failed.connect(_on_failed)
	Net.peer_left.connect(_on_peer_left)


# ── 매칭 시작 ──

func find_match(size: int, tag: String = "") -> void:
	mode_size = size
	lobby_tag = tag
	state = SEEKING
	_settle = 0.0
	_elapsed = 0.0
	_last_seen = {}
	members = []
	teams = {}
	alive = {}
	_room = ""
	state_changed.emit("seeking", "상대를 찾는 중…")
	Net.connect_room("lobby-%d%s" % [size, lobby_tag], true)


func cancel() -> void:
	state = IDLE
	Net.close()
	state_changed.emit("idle", "")


func _on_joined() -> void:
	if state == SEEKING:
		# 로비에 내가 왔음을 알린다. hello 는 net.gd 가 이미 보냈고, 여기서 찾는다는 뜻을 더한다
		Net.send("seek", {"size": mode_size, "name": Game.nickname})
		_last_seen[Net.me] = Game.nickname
		_settle = 0.0
	elif state == MATCHED:
		state = PLAYING
		Net.send("ready", {"name": Game.nickname})
		state_changed.emit("playing", "")
		match_started.emit(my_team, members)


func _on_failed(reason: String) -> void:
	if state == SEEKING or state == MATCHED:
		state = IDLE
		state_changed.emit("failed", reason)
	elif state == PLAYING:
		state = DONE
		match_over.emit(false, "연결이 끊겼어요")


func _on_peer_left(key: String) -> void:
	if state == SEEKING:
		_last_seen.erase(key)
		_settle = 0.0
	elif state == PLAYING and alive.has(key):
		# 나간 사람은 진 것으로 본다 — 끊고 도망가서 무승부가 되는 걸 막는다
		alive[key] = false
		_check_end()


func _on_msg(event: String, payload: Dictionary) -> void:
	var from := str(payload.get("from", ""))
	if from == "" or from == Net.me:
		return
	match event:
		"hello", "seek":
			if state == SEEKING:
				# ★ 처음 보는 상대에게만 되인사한다. 받을 때마다 인사하면 두 사람이 끝없이
				#   주고받으면서 정착 타이머가 영영 0 으로 되돌아가 매칭이 성립하지 않는다
				#   (실제로 그 버그로 두 피어가 서로를 보면서도 45초 동안 못 만났다).
				var known := _last_seen.has(from)
				_last_seen[from] = str(payload.get("name", "벌"))
				if not known:
					_settle = 0.0
					Net.send("seek", {"size": mode_size, "name": Game.nickname})
		"atk":
			if state == PLAYING and str(payload.get("to", "")) == Net.me:
				var n := int(payload.get("n", 0))
				if n > 0:
					attacked.emit(n)
		"board":
			if state == PLAYING:
				peer_board.emit(from, str(payload.get("b", "")), int(payload.get("s", 0)), bool(payload.get("d", false)))
		"dead":
			if state == PLAYING and alive.has(from):
				alive[from] = false
				_check_end()


func _process(delta: float) -> void:
	if state == SEEKING:
		_elapsed += delta
		_settle += delta
		if _last_seen.size() >= mode_size and _settle >= SETTLE:
			_form_room()
		elif _elapsed > LOBBY_TIMEOUT:
			state = IDLE
			Net.close()
			state_changed.emit("failed", "지금은 상대가 없어요")


# 모인 사람들의 key 를 정렬해 앞에서부터 mode_size 명을 끊는다.
# 같은 목록을 본 사람은 같은 방 이름과 같은 팀 배정을 계산한다 — 합의 절차가 필요 없다.
func _form_room() -> void:
	var keys: Array = _last_seen.keys()
	keys.sort()
	var group: Array = keys.slice(0, mode_size)
	if not group.has(Net.me):
		# 이번 판에 안 뽑혔다 — 다음 묶음을 기다린다
		_settle = 0.0
		return
	members = group
	teams = {}
	alive = {}
	for i in group.size():
		# 1v1 은 0/1, 2v2 는 0,0,1,1 로 앞뒤를 갈라 같은 편끼리 묶는다
		teams[group[i]] = 0 if i < group.size() / 2 else 1
		alive[group[i]] = true
	my_team = int(teams[Net.me])
	# 방 코드와 시드를 참가자 목록에서 결정론적으로 뽑는다 — 전원이 같은 값을 얻는다
	var joined_keys := ""
	for k in group:
		joined_keys += str(k) + "|"
	_room = "m-%08x" % Rng.hash_str(joined_keys)
	seed_value = int(Rng.hash_str("seed:" + joined_keys)) & 0x7FFFFFFF

	state = MATCHED
	state_changed.emit("matched", "상대를 찾았어요!")
	var my_key: String = str(Net.me)
	var am_host: bool = str(group[0]) == my_key
	Net.close()
	# 로비에서 쓰던 신원 그대로 방에 들어간다 — members/teams/alive 의 키가 그대로 유효해야
	# 상대의 공격·탈락 신호를 알아볼 수 있다
	Net.connect_room(_room, am_host, my_key)


# ── 대전 중 ──

func send_attack(amount: int) -> void:
	if state != PLAYING or amount <= 0:
		return
	var foes: Array = []
	for k in members:
		if k != Net.me and int(teams.get(k, 0)) != my_team and bool(alive.get(k, false)):
			foes.append(k)
	if foes.is_empty():
		return
	# 2v2 는 살아 있는 적 중 하나에게 — 몰아치지 않도록 매번 다른 쪽으로 돌린다
	var target: String = str(foes[randi() % foes.size()])
	Net.send("atk", {"to": target, "n": amount})


func sync_board(sess: Session) -> void:
	if state != PLAYING:
		return
	_sync += get_process_delta_time()
	if _sync < 1.0 / SYNC_HZ:
		return
	_sync = 0.0
	Net.send("board", {"b": sess.encode_board(), "s": sess.score, "d": sess.over})


func report_dead() -> void:
	if state != PLAYING:
		return
	alive[Net.me] = false
	Net.send("dead", {})
	_check_end()


func _check_end() -> void:
	if state != PLAYING:
		return
	var team_alive := {0: 0, 1: 0}
	for k in members:
		if bool(alive.get(k, false)):
			team_alive[int(teams.get(k, 0))] += 1
	if int(team_alive[my_team]) > 0 and int(team_alive[1 - my_team]) == 0:
		state = DONE
		match_over.emit(true, "상대 벌집이 무너졌어요!")
	elif int(team_alive[my_team]) == 0:
		state = DONE
		match_over.emit(false, "우리 벌집이 무너졌어요")


func team_name(t: int) -> String:
	if mode_size == 2:
		return "나" if t == my_team else "상대"
	return "우리 팀" if t == my_team else "상대 팀"
