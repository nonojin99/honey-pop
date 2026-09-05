# autoload `Net` — 대결 모드 네트워킹. Supabase Realtime 에 라이브러리 없이
# raw WebSocket(phoenix)으로 붙는다.
#
# ★ 이 파일은 dot-atelier-godot/scripts/net.gd 의 이식본이다. 그쪽에서 2·3·4인 실제 소켓
#   통합 테스트를 통과한 코드라, 프로토콜을 새로 짜지 않고 그대로 쓴다.
#   허니 팝은 판 전체가 아니라 **시드 + 발사 각도**만 주고받는다 (session.gd 가 순수하므로
#   같은 시드 + 같은 입력 = 같은 판이 보장된다). 그래서 대역폭이 발당 수십 바이트다.
#
#   topic     realtime:honey-pop:<방코드>
#   join      phx_join {config:{broadcast:{self:false,ack:false}, presence:{key:<내ID>}, private:false}}
#   heartbeat 25초마다 {topic:"phoenix", event:"heartbeat"}
#
# ★ 입장 발견은 presence 가 아니라 hello 핸드셰이크로 한다.
#   Supabase 는 join 시점에 presence_state 를 보내주지 않아서, 나중에 들어온 쪽이 먼저 있던
#   사람을 영영 모른다. presence 는 "나갔다"를 감지하는 용도로만 믿는다.
#
# ★ broadcast 에 발신자가 안 실린다 — payload 에 from 을 직접 넣는다.
extends Node

signal joined()
signal failed(reason: String)
signal msg(event: String, payload: Dictionary)
signal peers_changed()
signal peer_left(key: String)

const HEARTBEAT := 25.0
const JOIN_TIMEOUT := 8.0

var ws: WebSocketPeer = null
var topic := ""
var ref_no := 0
var is_joined := false
var room := ""
var me := ""
var is_host := false
var members: Dictionary = {}    # presenceKey -> {name, host}

var _hb := 0.0
var _wait := 0.0
var _join_sent := false
var _url := ""


func _ready() -> void:
	set_process(true)


func net_id() -> String:
	var t := Time.get_ticks_usec()
	return "p%d-%d" % [t % 100000, (hash(str(t) + str(randi())) & 0xFFFFF)]


# id_override 를 주면 그 신원 그대로 새 채널에 들어간다.
# ★ 대결 모드가 로비 → 방으로 옮길 때 필요하다. 매번 새 id 를 발급하면 로비에서 정한
#   참가자 명단(누가 어느 팀인지, 누가 살아 있는지)의 키가 방에서 전부 어긋나서
#   상대의 "탈락" 신호를 영영 못 알아본다 (실제로 그 버그로 승패 판정이 안 났다).
func connect_room(r: String, host: bool, id_override: String = "") -> void:
	close()
	room = r
	is_host = host
	me = id_override if id_override != "" else (("H:" if host else "G:") + net_id())
	topic = "realtime:%s:%s" % [_g().GAME_ID, r]
	ref_no = 0
	_hb = 0.0
	_wait = 0.0
	_join_sent = false
	_url = str(_g().SB_URL).replace("https://", "wss://") + "/realtime/v1/websocket?apikey=" + str(_g().SB_KEY) + "&vsn=1.0.0"
	ws = WebSocketPeer.new()
	if ws.connect_to_url(_url) != OK:
		ws = null
		failed.emit("연결 실패")


func close() -> void:
	if ws != null:
		ws.close()
	ws = null
	is_joined = false
	members = {}


func _next_ref() -> String:
	ref_no += 1
	return str(ref_no)


func send(ev: String, payload: Dictionary = {}) -> void:
	if ws == null or not is_joined or ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	var body := {"from": me}
	for k in payload.keys():
		body[k] = payload[k]
	ws.send_text(JSON.stringify({
		"topic": topic, "event": "broadcast",
		"payload": {"type": "broadcast", "event": ev, "payload": body},
		"ref": _next_ref(),
	}))


func track() -> void:
	if ws == null or ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	ws.send_text(JSON.stringify({
		"topic": topic, "event": "presence",
		"payload": {"type": "presence", "event": "track", "payload": {"name": me, "host": is_host}},
		"ref": _next_ref(),
	}))


func peer_keys() -> Array:
	var out: Array = []
	for k in members.keys():
		if str(k) != me:
			out.append(str(k))
	return out


func peer_count() -> int:
	return members.size()


func _process(delta: float) -> void:
	if ws == null:
		return
	ws.poll()
	var state := ws.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		if not is_joined:
			if not _join_sent:
				_join_sent = true
				_send_join()
			_wait += delta
			if _wait > JOIN_TIMEOUT:
				close()
				failed.emit("연결 시간 초과")
				return
		else:
			_hb += delta
			if _hb >= HEARTBEAT:
				_hb = 0.0
				ws.send_text(JSON.stringify({"topic": "phoenix", "event": "heartbeat", "payload": {}, "ref": _next_ref()}))
		while ws.get_available_packet_count() > 0:
			_on_packet(ws.get_packet().get_string_from_utf8())
	elif state == WebSocketPeer.STATE_CLOSED:
		var was := is_joined
		close()
		failed.emit("연결이 끊겼어요" if was else "연결 실패")


func _send_join() -> void:
	ws.send_text(JSON.stringify({
		"topic": topic, "event": "phx_join", "ref": _next_ref(),
		"payload": {"config": {
			"broadcast": {"self": false, "ack": false},
			"presence": {"key": me},
			"private": false,
		}},
	}))


func _pres_meta(entry: Variant) -> Dictionary:
	var m := {}
	if typeof(entry) == TYPE_DICTIONARY and entry.has("metas"):
		var metas: Array = entry["metas"]
		if metas.size() > 0:
			m = metas[0]
	return {"name": str(m.get("name", "?")), "host": bool(m.get("host", false))}


func _on_packet(txt: String) -> void:
	var m = JSON.parse_string(txt)
	if typeof(m) != TYPE_DICTIONARY:
		return
	var ev := str(m.get("event", ""))
	var pl = m.get("payload")
	match ev:
		"phx_reply":
			if typeof(pl) == TYPE_DICTIONARY and str(pl.get("status", "")) == "ok" and not is_joined:
				is_joined = true
				members[me] = {"name": me, "host": is_host}
				track()
				send("hello", {"host": is_host})    # 입장 발견은 이 핸드셰이크가 담당한다
				joined.emit()
			elif typeof(pl) == TYPE_DICTIONARY and str(pl.get("status", "")) == "error" and not is_joined:
				close()
				failed.emit("채널 입장 거부")
		"presence_state":
			members = {}
			if typeof(pl) == TYPE_DICTIONARY:
				for k in pl.keys():
					members[str(k)] = _pres_meta(pl[k])
			peers_changed.emit()
		"presence_diff":
			# presence 는 "나갔다"를 아는 용도로만 믿는다 (입장 발견은 hello)
			if typeof(pl) == TYPE_DICTIONARY:
				var joins = pl.get("joins", {})
				if typeof(joins) == TYPE_DICTIONARY:
					for k in joins.keys():
						members[str(k)] = _pres_meta(joins[k])
				var leaves = pl.get("leaves", {})
				if typeof(leaves) == TYPE_DICTIONARY:
					for k in leaves.keys():
						members.erase(str(k))
						peer_left.emit(str(k))
			peers_changed.emit()
		"broadcast":
			if typeof(pl) == TYPE_DICTIONARY:
				var inner = pl.get("payload", {})
				msg.emit(str(pl.get("event", "")), inner if typeof(inner) == TYPE_DICTIONARY else {})
		"phx_error", "phx_close":
			close()
			failed.emit("연결이 끊겼어요")


# Game 오토로드 지연 해석 — `--script` 로 도구를 돌릴 때 preload 체인에서 오토로드 식별자가
# 안 풀리는 경우가 있다(실제로 겪음: coop_test 가 play.gd 컴파일에서 "Identifier not found: Game").
# 노드로 잡으면 게임에서도 도구에서도 같은 코드가 돈다.
var _game: Node = null


func _g() -> Node:
	if _game == null:
		# get_tree() 는 노드가 트리에 붙기 전이면 null 이다 (도구 스크립트의 첫 프레임 전).
		# 메인 루프에서 직접 잡으면 그 창도 피한다.
		var ml := Engine.get_main_loop()
		if ml is SceneTree:
			_game = (ml as SceneTree).root.get_node_or_null("Game")
	return _game
