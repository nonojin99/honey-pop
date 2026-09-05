# autoload `Game` — 설정·기록·랭킹·플레이 로그.
#
# 랭킹은 Daily Game Project 공용 규약을 따른다:
#   · (game_id, nickname) 당 최고 점수 1행만 — DB 트리거 daily_rankings_keep_best 가 강제한다.
#     클라이언트는 그냥 insert 하면 된다.
#   · 게임오버 화면은 "내 최고 기록 N점 — 현재 M위"
#   · 랭킹은 전부 실패해도 게임은 완전히 동작해야 한다 (오프라인/웹 CORS 차단 대비)
extends Node

const GAME_ID := "honey-pop"

# 프로젝트 A "nonojin99" — 게임 저장소 + 홀수일 랭킹
const SB_URL := "https://fpjgjwazqpfiffnsgume.supabase.co"
const SB_KEY := "sb_publishable_I1YgcnYNBOaGy0WwozO2wQ_PGwsLtU5"

# 플레이 로그는 랭킹 DB 가 어느 쪽이든 항상 프로젝트 A 로 (주간 리포트 데이터원)
const LOG_URL := SB_URL + "/rest/v1/play_events"
const LOG_KEY := SB_KEY

const SAVE_PATH := "user://honey-pop.cfg"

var nickname := ""
var best_score := 0
var best_round := 0
var sound_on := true

signal top_loaded(rows: Array)
signal rank_loaded(rank: int, best: int)


func _ready() -> void:
	_load()
	log_event("load")


# ── 저장 ──

func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return
	nickname = str(cfg.get_value("player", "nickname", ""))
	best_score = int(cfg.get_value("player", "best_score", 0))
	best_round = int(cfg.get_value("player", "best_round", 0))
	sound_on = bool(cfg.get_value("player", "sound_on", true))


func save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("player", "nickname", nickname)
	cfg.set_value("player", "best_score", best_score)
	cfg.set_value("player", "best_round", best_round)
	cfg.set_value("player", "sound_on", sound_on)
	cfg.save(SAVE_PATH)


func note_result(score: int, round_no: int) -> bool:
	var is_best := score > best_score
	if is_best:
		best_score = score
	if round_no > best_round:
		best_round = round_no
	save()
	return is_best


# ── HTTP 공통 ──

func _headers() -> PackedStringArray:
	return PackedStringArray([
		"apikey: " + SB_KEY,
		"Authorization: Bearer " + SB_KEY,
		"Content-Type: application/json",
	])


func _request(url: String, method: int, body: String, headers: PackedStringArray) -> Array:
	var http := HTTPRequest.new()
	add_child(http)
	http.timeout = 8.0
	var err := http.request(url, headers, method, body)
	if err != OK:
		http.queue_free()
		return [false, 0, PackedStringArray(), PackedByteArray()]
	var res: Array = await http.request_completed
	http.queue_free()
	# [result, response_code, headers, body]
	var ok: bool = res[0] == HTTPRequest.RESULT_SUCCESS and int(res[1]) >= 200 and int(res[1]) < 300
	return [ok, int(res[1]), res[2], res[3]]


# ── 플레이 로그 (load / start / over) ──
# 실패해도 조용히 넘긴다. 게임 흐름을 절대 막지 않는다
func log_event(event: String, score: Variant = null) -> void:
	var body := {"game_id": GAME_ID, "event": event}
	if score != null:
		body["score"] = score
	_request(LOG_URL, HTTPClient.METHOD_POST, JSON.stringify(body), _headers())


# ── 랭킹 ──

func fetch_top(limit: int = 5) -> Array:
	var url := "%s/rest/v1/daily_rankings?game_id=eq.%s&select=nickname,score&order=score.desc,created_at.asc&limit=%d" % [SB_URL, GAME_ID, limit]
	var res := await _request(url, HTTPClient.METHOD_GET, "", _headers())
	if not res[0]:
		top_loaded.emit([])
		return []
	var parsed = JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())
	var rows: Array = parsed if typeof(parsed) == TYPE_ARRAY else []
	top_loaded.emit(rows)
	return rows


func submit_score(nick: String, score: int) -> bool:
	if nick.strip_edges() == "":
		return false
	var body := JSON.stringify({"game_id": GAME_ID, "nickname": nick.substr(0, 20), "score": score})
	var res := await _request(SB_URL + "/rest/v1/daily_rankings", HTTPClient.METHOD_POST, body, _headers())
	return res[0]


# 서버 트리거가 최고점만 남기므로, 등록 뒤 내 행을 다시 읽으면 그게 곧 내 최고 기록
func fetch_my_best(nick: String) -> int:
	var url := "%s/rest/v1/daily_rankings?game_id=eq.%s&nickname=eq.%s&select=score&limit=1" % [SB_URL, GAME_ID, nick.uri_encode()]
	var res := await _request(url, HTTPClient.METHOD_GET, "", _headers())
	if not res[0]:
		return -1
	var parsed = JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())
	if typeof(parsed) == TYPE_ARRAY and (parsed as Array).size() > 0:
		return int(parsed[0].get("score", 0))
	return -1


# 나보다 높은 점수의 개수 + 1 = 내 순위
func fetch_rank(score: int) -> int:
	var url := "%s/rest/v1/daily_rankings?game_id=eq.%s&score=gt.%d&select=nickname" % [SB_URL, GAME_ID, score]
	var headers := _headers()
	headers.append("Prefer: count=exact")
	headers.append("Range: 0-0")
	var res := await _request(url, HTTPClient.METHOD_GET, "", headers)
	if not res[0]:
		return -1
	for h in (res[2] as PackedStringArray):
		var line := str(h)
		if line.to_lower().begins_with("content-range:"):
			var total := line.split("/")[-1].strip_edges()
			if total.is_valid_int():
				return int(total) + 1
	return -1


# 게임오버 흐름 한 번에: 등록 → 내 최고 → 순위
func submit_and_rank(nick: String, score: int) -> Dictionary:
	var okay := await submit_score(nick, score)
	if not okay:
		return {"ok": false, "best": -1, "rank": -1}
	var mine := await fetch_my_best(nick)
	if mine < 0:
		return {"ok": false, "best": -1, "rank": -1}
	var rank := await fetch_rank(mine)
	rank_loaded.emit(rank, mine)
	return {"ok": true, "best": mine, "rank": rank}
