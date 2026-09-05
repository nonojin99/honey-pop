# 시드 난수 — LCG. 게임플레이 결정에 randi()/randf() 를 쓰지 않는다.
#
# 프로젝트 룰(dot-atelier CLAUDE.md 2번): 판 생성이 곧 기록 공정성이다. 같은 시드는 어디서든
# 같은 판을 낸다 — 봇 시뮬이 재현 가능해야 하고(harness.md 1번), 대결 모드에서 두 기기가
# **같은 판**을 봐야 하기 때문이다(시드만 주고받으면 판 전체를 동기화할 필요가 없다).
class_name Rng
extends RefCounted

const MASK := 0xFFFFFFFF

var _s: int


func _init(seed_value: int) -> void:
	var s := seed_value & MASK
	_s = s if s != 0 else 1


func next() -> float:
	_s = (_s * 1664525 + 1013904223) & MASK
	return float(_s) / 4294967296.0


func next_int(n: int) -> int:
	if n <= 0:
		return 0
	return mini(n - 1, int(next() * float(n)))


func pick(arr: Array) -> Variant:
	return arr[next_int(arr.size())]


# 문자열 → 시드 (FNV-1a). 방 코드로 판을 맞출 때 쓴다
static func hash_str(s: String) -> int:
	var h := 2166136261
	for i in s.length():
		h = (((h ^ s.unicode_at(i)) & MASK) * 16777619) & MASK
	return h
