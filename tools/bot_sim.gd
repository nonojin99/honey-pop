# 봇 플레이어 시뮬레이션 (배포 전 필수 룰 — harness.md)
#
#   godot --headless --path . --script res://tools/bot_sim.gd [-- --seeds 40]
#
# Royale 하네스의 발상을 그대로 가져왔다: **두 봇의 차이가 곧 그 요소의 가치다.**
# 여기서는 "축2(꽃가루)를 쓰는 봇 vs 무시하는 봇"의 점수 차이로 2축 설계가 진짜인지 잰다.
#
# ★ 스킬 기본형은 난이도 수식을 JS 시뮬로 따로 옮겨 적지만, 여기서는 session.gd 를 **그대로**
#   굴린다. 시뮬과 게임이 갈릴 여지가 없다 (board.gd 가 순수 연산이라 가능한 방식).
#
# ── 봇 모델 ──
# 봇은 매 발 (각도, 조준시간) 두 값을 정한다. 이 한 쌍이 곧 2축 의사결정이다.
#   · 조준 시간이 길수록 각도 오차 σ 가 지수적으로 준다 (축1 이득)
#   · 조준 시간은 꽃가루를 먹는다 (축2 비용)
# AXIS1_ONLY 는 SKILLED 와 **조준 실력이 완전히 같고** 축2 정책만 다르다. 그래야 점수 차이가
# 오롯이 축2 의 가치가 된다.
extends SceneTree

const AIM_MIN := 0.22
const AIM_MAX := 2.50

# 각도 오차: σ(t) = σ_min + (σ_0 - σ_min)·exp(-t/τ)  — 조준할수록 정확해진다
const SIG_0 := 0.22      # 조준 0초일 때 표준편차(라디안, 약 12.6°)
const SIG_MIN := 0.012   # 아무리 조준해도 남는 손떨림(약 0.7°)
const TAU := 0.70

const MAX_SHOTS := 400   # 이 발수를 넘기면 "무한 생존"으로 본다 (난이도 플래토 판정)
const INTRO_TARGET := 1  # 초보가 넘어야 할 도입부 = 라운드 0 클리어

var seeds := 40

# sigma  조준 오차 배율(실력)      plan  최선 각도를 실제로 고를 확률(판단력)
# cand   후보 각도 수(탐색 폭)     f     남은 꽃가루 중 한 발에 쓰는 비율(축2 정책)
# topk   판단이 어긋났을 때 고르는 후보 범위 — 초보라도 화면에 조준선이 그려지므로
#        "아무 데나 쏜다"가 아니라 "괜찮지만 최선은 아닌 자리를 고른다"가 현실적인 모델이다.
#        (처음엔 균등 무작위로 뒀는데, 그건 화면을 안 보는 사람의 모델이라 초보를 과소평가했다)
const BOTS := {
	"SKILLED":    {"sigma": 0.5, "plan": 0.95, "cand": 31, "topk": 2, "policy": "adaptive", "f": 0.18},
	"NORMAL":     {"sigma": 1.0, "plan": 0.78, "cand": 25, "topk": 4, "policy": "adaptive", "f": 0.28},
	"NOVICE":     {"sigma": 2.0, "plan": 0.55, "cand": 17, "topk": 8, "policy": "adaptive", "f": 0.38},
	# ★ SKILLED 와 실력·판단력·탐색폭이 전부 같다. 다른 건 축2 정책 하나뿐이다
	"AXIS1_ONLY": {"sigma": 0.5, "plan": 0.95, "cand": 31, "topk": 2, "policy": "max", "f": 0.0},
}

var _results := {}


func _initialize() -> void:
	_parse_args()
	print("봇 시뮬 — 봇 4종 × 시드 %d판 (session.gd 를 그대로 굴린다)" % seeds)
	for name in BOTS.keys():
		_results[name] = _run_bot(str(name))
		var r: Dictionary = _results[name]
		print("  %-11s 중앙값 %5d점 (라운드 %.1f) · 상위10%% %5d점 · 최고 %5d점 · 무한생존 %d판 · 평균 %d발"
			% [name, r["median"], r["median_round"], r["p90"], r["max"], r["infinite"], r["avg_shots"]])
	_judge()


func _parse_args() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if str(args[i]) == "--seeds" and i + 1 < args.size():
			seeds = maxi(4, int(str(args[i + 1])))


func _run_bot(name: String) -> Dictionary:
	var cfg: Dictionary = BOTS[name]
	var scores: Array = []
	var rounds: Array = []
	var shots_total := 0
	var infinite := 0
	var dry_total := 0
	var desc_total := 0
	for s in seeds:
		var seed_value := 7000 + s * 6151
		var sess := Session.new(seed_value, 0)
		var rng := Rng.new(seed_value ^ 0x5A5A)
		var shots := 0
		while not sess.over and shots < MAX_SHOTS:
			var t := _aim_time(sess, cfg)
			var a := _choose_angle(sess, cfg, rng)
			a += _gauss(rng) * _sigma(t, float(cfg["sigma"]))
			sess.fire(a, t)
			shots += 1
		if not sess.over:
			infinite += 1
		scores.append(sess.score)
		rounds.append(sess.round_no)
		shots_total += shots
		dry_total += sess.dry_events
		desc_total += sess.descends
	scores.sort()
	rounds.sort()
	return {
		"median": int(scores[scores.size() / 2]),
		"median_round": float(rounds[rounds.size() / 2]),
		"p90": int(scores[mini(scores.size() - 1, int(float(scores.size()) * 0.9))]),
		"max": int(scores[scores.size() - 1]),
		"infinite": infinite,
		"avg_shots": shots_total / maxi(1, seeds),
		"avg_dry": float(dry_total) / float(maxi(1, seeds)),
		"avg_desc": float(desc_total) / float(maxi(1, seeds)),
		"intro_pass": _intro_pass_rate(rounds),
	}


func _intro_pass_rate(rounds: Array) -> float:
	var n := 0
	for r in rounds:
		if int(r) >= INTRO_TARGET:
			n += 1
	return float(n) / float(maxi(1, rounds.size()))


# ── 축2 정책: 이번 발에 조준을 얼마나 할 것인가 ──
func _aim_time(sess: Session, cfg: Dictionary) -> float:
	if str(cfg["policy"]) == "max":
		# 축2를 아예 안 본다. 꽃가루가 얼마 남았든 항상 최대로 조준한다
		return AIM_MAX
	# 남은 꽃가루로 살 수 있는 시간 중 f 만큼만 쓴다 — 마르면 알아서 서두르게 된다
	var remaining := sess.pollen / Difficulty.drain_rate(sess.round_no)
	return clampf(float(cfg["f"]) * remaining, AIM_MIN, AIM_MAX)


func _sigma(t: float, mult: float) -> float:
	return (SIG_MIN + (SIG_0 - SIG_MIN) * exp(-t / TAU)) * mult


# ── 축1: 각도 고르기 ──
func _choose_angle(sess: Session, cfg: Dictionary, rng: Rng) -> float:
	var cand := int(cfg["cand"])
	var landed: Array = []      # [{a, gain}]
	for i in cand:
		var a: float = lerpf(-Session.MAX_ANGLE, Session.MAX_ANGLE, float(i) / float(cand - 1))
		var pv := sess.preview(a)
		if not pv["ok"]:
			continue
		landed.append({"a": a, "gain": float(pv["gain"])})
	if landed.is_empty():
		return 0.0
	landed.sort_custom(func(x, y): return float(x["gain"]) > float(y["gain"]))
	# 판단력 — 최선을 못 알아보면 상위 topk 중에서 고른다
	if rng.next() < float(cfg["plan"]):
		return float(landed[0]["a"])
	var k: int = mini(int(cfg["topk"]), landed.size())
	return float(landed[rng.next_int(maxi(1, k))]["a"])


# Box-Muller. 시드 기반이라 재현된다
func _gauss(rng: Rng) -> float:
	var u1: float = maxf(1e-9, rng.next())
	var u2: float = rng.next()
	return sqrt(-2.0 * log(u1)) * cos(TAU_CONST * u2)

const TAU_CONST := 6.283185307179586


# ── 합격 판정 (harness.md 표) ──
func _judge() -> void:
	var sk: Dictionary = _results["SKILLED"]
	var no: Dictionary = _results["NORMAL"]
	var nv: Dictionary = _results["NOVICE"]
	var a1: Dictionary = _results["AXIS1_ONLY"]
	var fails: Array = []

	print("")
	# ① 초보 도입부 통과
	if float(nv["median_round"]) < float(INTRO_TARGET):
		fails.append("초보 도입부: NOVICE 중앙 라운드 %.1f < %d — 첫 경험에서 좌절한다"
			% [nv["median_round"], INTRO_TARGET])
	print("① 초보 도입부 통과율 %.0f%% (NOVICE 중앙 라운드 %.1f)"
		% [float(nv["intro_pass"]) * 100.0, nv["median_round"]])

	# ② 고수 유한 생존 — 무한 생존이 있으면 난이도가 결국 안 조여진다는 뜻
	if int(sk["infinite"]) > 0:
		fails.append("고수 유한 생존: SKILLED 가 %d판에서 %d발까지 안 죽었다 — 난이도 플래토"
			% [sk["infinite"], MAX_SHOTS])
	print("② 고수 무한생존 %d판 (0이어야 함)" % sk["infinite"])

	# ③ 실력 변별력 — 랭킹 경쟁의 전제
	var r1 := float(sk["median"]) / maxf(1.0, float(no["median"]))
	var r2 := float(no["median"]) / maxf(1.0, float(nv["median"]))
	if r1 < 1.4:
		fails.append("변별력: 고수/중수 %.2f배 < 1.4배" % r1)
	if r2 < 1.4:
		fails.append("변별력: 중수/초보 %.2f배 < 1.4배" % r2)
	print("③ 변별력 고수/중수 %.2f배 · 중수/초보 %.2f배 (각 1.4배 이상)" % [r1, r2])

	# ④ 축2 가치 — 2축 설계가 진짜인지 장식인지의 판정
	var axis2 := float(sk["median"]) / maxf(1.0, float(a1["median"]))
	if axis2 < 1.5:
		fails.append("축2 가치: SKILLED/AXIS1_ONLY %.2f배 < 1.5배 — 꽃가루가 장식이다" % axis2)
	print("④ 축2 가치 %.2f배 (1.5배 이상이어야 2축이 성립)" % axis2)
	print("   AXIS1_ONLY 는 조준 실력이 SKILLED 와 같다. 차이는 꽃가루를 보느냐뿐이다.")
	print("   판당 게이지 고갈 %.1f회 vs %.1f회 · 벌집 하강 %.1f회 vs %.1f회 (SKILLED vs AXIS1_ONLY)"
		% [sk["avg_dry"], a1["avg_dry"], sk["avg_desc"], a1["avg_desc"]])

	print("")
	if fails.is_empty():
		print("PASS — 봇 4종 총당전 전 항목 통과")
		quit(0)
	else:
		for f in fails:
			print("[봇] " + f)
		print("FAIL — %d 건" % fails.size())
		quit(1)
