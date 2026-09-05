# autoload `Sfx` — 효과음을 파형으로 합성한다. 오디오 에셋 파일이 없다.
#
# 웹 빌드 용량이 곧 첫 로딩 시간이라(Godot 웹 빌드는 이미 20MB대), 사운드는 코드로 만든다.
# 8비트 신스 느낌: 사각파 + 지수 감쇠 엔벨로프.
extends Node

const RATE := 22050
const VOICES := 6

var _players: Array[AudioStreamPlayer] = []
var _next := 0
var _cache: Dictionary = {}


func _ready() -> void:
	for i in VOICES:
		var p := AudioStreamPlayer.new()
		p.bus = "Master"
		add_child(p)
		_players.append(p)


func _play(stream: AudioStream, volume_db: float) -> void:
	if not Game.sound_on:
		return
	var p := _players[_next]
	_next = (_next + 1) % VOICES
	p.stream = stream
	p.volume_db = volume_db
	p.play()


# 사각파 + 지수 감쇠. f0 → f1 로 주파수를 훑는다(상승시키면 상쾌하고, 하강시키면 실패로 들린다)
func _tone(f0: float, f1: float, dur: float, duty: float = 0.5, decay: float = 6.0) -> AudioStreamWAV:
	var key := "%0.1f_%0.1f_%0.3f_%0.2f_%0.1f" % [f0, f1, dur, duty, decay]
	if _cache.has(key):
		return _cache[key]
	var n := int(RATE * dur)
	var data := PackedByteArray()
	data.resize(n * 2)
	var phase := 0.0
	for i in n:
		var t := float(i) / float(n)
		var f: float = lerpf(f0, f1, t)
		phase += f / float(RATE)
		phase = fmod(phase, 1.0)
		var s := 1.0 if phase < duty else -1.0
		var env: float = exp(-decay * t) * (1.0 - t * 0.15)
		var v := int(clampf(s * env * 9000.0, -32000.0, 32000.0))
		if v < 0:
			v += 65536
		data[i * 2] = v & 0xFF
		data[i * 2 + 1] = (v >> 8) & 0xFF
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = data
	_cache[key] = w
	return w


# 짧은 노이즈 — 터짐·낙하의 질감
func _noise(dur: float, decay: float = 12.0, seed_value: int = 7) -> AudioStreamWAV:
	var key := "n_%0.3f_%0.1f_%d" % [dur, decay, seed_value]
	if _cache.has(key):
		return _cache[key]
	var n := int(RATE * dur)
	var data := PackedByteArray()
	data.resize(n * 2)
	var s := seed_value
	for i in n:
		s = (s * 1664525 + 1013904223) & 0xFFFFFFFF
		var r := (float(s) / 4294967296.0) * 2.0 - 1.0
		var env: float = exp(-decay * (float(i) / float(n)))
		var v := int(clampf(r * env * 7000.0, -32000.0, 32000.0))
		if v < 0:
			v += 65536
		data[i * 2] = v & 0xFF
		data[i * 2 + 1] = (v >> 8) & 0xFF
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = data
	_cache[key] = w
	return w


# ── 효과음 ──

func shoot() -> void:
	_play(_tone(680.0, 420.0, 0.07, 0.35, 14.0), -14.0)


func bounce() -> void:
	_play(_tone(320.0, 300.0, 0.04, 0.5, 20.0), -22.0)


func stick() -> void:
	_play(_tone(240.0, 200.0, 0.06, 0.5, 16.0), -20.0)


# 연쇄가 길수록 음이 올라간다 — 점수에 비례해 주파수를 올리면 체감이 상쾌해진다
func pop(chain: int) -> void:
	var base := 520.0 + 90.0 * float(mini(chain, 8))
	_play(_tone(base, base * 1.6, 0.12, 0.5, 9.0), -11.0)


func drop(count: int) -> void:
	_play(_tone(420.0, 140.0, 0.22 + 0.02 * float(mini(count, 8)), 0.25, 5.0), -12.0)
	_play(_noise(0.18, 10.0, 13), -20.0)


func descend() -> void:
	_play(_tone(180.0, 110.0, 0.30, 0.5, 4.0), -12.0)


# 게이지 고갈 — 축2를 놓쳤다는 신호라 확실히 들려야 한다
func dry() -> void:
	_play(_tone(300.0, 90.0, 0.42, 0.3, 3.0), -9.0)


func round_clear() -> void:
	for i in 4:
		var f := 440.0 * pow(1.26, float(i))
		var tw := get_tree().create_timer(0.09 * float(i))
		tw.timeout.connect(func(): _play(_tone(f, f * 1.02, 0.16, 0.5, 6.0), -11.0))


func game_over() -> void:
	for i in 3:
		var f := 400.0 / pow(1.22, float(i))
		var tw := get_tree().create_timer(0.14 * float(i))
		tw.timeout.connect(func(): _play(_tone(f, f * 0.9, 0.28, 0.5, 4.0), -10.0))


func ui() -> void:
	_play(_tone(760.0, 900.0, 0.05, 0.5, 18.0), -17.0)


func warn() -> void:
	_play(_tone(520.0, 520.0, 0.09, 0.5, 12.0), -15.0)
