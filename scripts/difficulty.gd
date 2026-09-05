# 난이도 곡선 — 이 파일이 모든 난이도 파라미터의 유일한 진실 원천이다.
#
# 프로젝트 룰(design-principles 4장): "수식 먼저, 코드 나중". 모든 파라미터는
#   param(n) = 하한 + 여유 × 감쇠^n
# 형태의 단조 곡선이어야 한다. 상수 상한을 두면 플래토가 생긴다(코스모 핀 교훈).
#
# n = 라운드 인덱스(0-based). 라운드는 판을 다 비우면 오른다.
#
# ── 축 구조 ──
#   축1(즉각 조작) 조준 정밀도 — 각도를 읽고 벽 반사를 계산해 좁은 틈에 넣는다
#   축2(누적 관리) 꽃가루 게이지 — 시간이 흐르면 줄고, 터뜨리면 찬다. 마르면 벌집이 내려온다
#
#   두 축이 서로를 무는 지점: 조준을 오래 끌면 정확해지지만(축1 이득) 게이지가 마르고(축2 비용),
#   서두르면 게이지는 아끼지만 빗나가 벌집이 커져 회복 기회 자체가 줄어든다.
#   → T_BUDGET 이 이 압박의 세기를 정하는 손잡이다.
class_name Difficulty
extends RefCounted

# ── 축2: 가득 찬 게이지로 "조준만 하며" 버틸 수 있는 시간(초) ──
# 도입부는 하한의 3.6배로 관대하게 시작해 하한으로 수렴한다(design-principles 4장: 3~4배).
const T_BUDGET_MIN := 2.5      # 하한. 최소 매치 조준 여유가 0.60s 로 인간 하한 0.25s 의 2.4배
const T_BUDGET_0 := 9.0        # 라운드 0 값 = 하한의 3.6배
const T_BUDGET_DECAY := 0.90   # 약 라운드 22에서 하한의 1.35배로 점근

const POLLEN_MAX := 100.0

# ── 게이지 수지(收支) ──
const RECOVER_PER_POP := 8.0    # 매치로 터진 구슬 1개당 회복
const RECOVER_PER_DROP := 5.0   # 연결이 끊겨 떨어진 구슬 1개당 회복
const MISS_COST := 6.0          # 매치 실패(3개 미만)했을 때 즉시 소모
const DRY_REFILL := 0.40        # 게이지 고갈 시 재충전 비율 — 고갈은 즉사가 아니라 "한 줄 하강"이다
                                # (하네스 교훈: 즉사로 만들면 축2가 도박이 되고 2축이 무너진다)

# ── 축1: 판 구성 ──
const COLORS_MIN := 3
const COLORS_MAX := 6           # 6색 초과는 3초 이해를 해친다(색 구분이 안 됨)
const COLORS_EVERY := 3         # 3라운드마다 색 +1

const ROWS_0 := 2               # 첫 판은 2줄 18개 — 초보가 첫 라운드를 반드시 넘도록
const ROWS_MAX := 7
const ROWS_EVERY := 2           # 2라운드마다 시작 줄 +1

# ── 발사 횟수 기반 하강 ──
# ★ 이 값은 봇 시뮬 결과로 크게 늦춘 것이다(12→26, 4→9).
#   원래 값에서는 하강의 76%를 이 카운터가 만들었고, 그 결과 꽃가루를 관리하는 봇과 무시하는
#   봇의 하강 횟수가 24.6 vs 24.5 로 사실상 같아졌다 — 축2 가치가 1.43배에 묶인 원인이다.
#   이 카운터는 두 축 어디에도 안 붙은 맹목적 압박이라, 세면 축2를 희석시킨다.
#   지금은 "아무것도 안 터뜨리고 버티기"만 막는 느린 안전장치 역할만 한다.
const SHOTS_MIN := 9.0
const SHOTS_0 := 26.0
const SHOTS_DECAY := 0.92

# ── 라운드 진행 할당량 ──
# ★ 봇 시뮬이 두 번째 구조 결함을 잡아냈다.
#   "판을 완전히 비워야 다음 라운드"로 두면, 하강이 9발마다 9개를 더하는데 좋은 한 발이
#   3~8개를 지우므로 판이 사실상 안 비워진다. 실제로 봇 4종이 전부 라운드 3에서 멈췄다.
#   그러면 라운드별 색 추가·배치 변화라는 진행 자체가 플레이어에게 영영 안 보인다.
#   그래서 "이 라운드에서 없앤 구슬 수"가 할당량을 넘으면 다음 라운드로 넘어간다.
#   완전 정리는 없어진 게 아니라 추가 보너스로 남는다.
const QUOTA_0 := 22
const QUOTA_STEP := 5           # 라운드가 오를수록 더 오래 걸린다


static func round_quota(n: int) -> int:
	return QUOTA_0 + QUOTA_STEP * n


# 보드 폭. 좌우 벽 반사가 성립하려면 최소 8열은 있어야 한다(공정성 룰 3)
const COLS := 9
const DEAD_ROW := 12            # 이 행에 구슬이 닿으면 게임오버


# 가득 찬 게이지로 버티는 시간(초). 단조 감소, 하한 T_BUDGET_MIN 으로 수렴
static func t_budget(n: int) -> float:
	return T_BUDGET_MIN + (T_BUDGET_0 - T_BUDGET_MIN) * pow(T_BUDGET_DECAY, float(n))


# ── 라운드 내부 압박 상승 ──
# ★ 봇 시뮬이 잡아낸 구조 결함의 해결책이다.
#   난이도가 round_no 에만 걸려 있는데 라운드는 "판을 다 비워야" 오른다. 그래서 클리어는 못
#   하지만 죽지도 않는 플레이어는 난이도가 영원히 고정된다 — 실제로 봇 4종이 전부 라운드 3에서
#   멈췄고 고수는 400발까지 안 죽었다(무한 생존 = 난이도 플래토).
#   같은 판에서 오래 끌수록 벌집이 배고파진다: 발마다 감소율이 조금씩 오르고 2배에서 멈춘다.
#   상한을 둔 이유는 공정성이다 — 상한이 없으면 최소 매치 조준 여유가 인간 하한 아래로 간다.
const ESCALATE_PER_SHOT := 0.012
const ESCALATE_MAX := 2.0


static func escalation(shots_in_round: int) -> float:
	return minf(ESCALATE_MAX, 1.0 + ESCALATE_PER_SHOT * float(maxi(0, shots_in_round)))


# 초당 꽃가루 감소량. t_budget 의 역수라 두 값이 어긋날 수 없다
static func drain_rate(n: int, shots_in_round: int = 0) -> float:
	return (POLLEN_MAX / t_budget(n)) * escalation(shots_in_round)


# 이 라운드에 등장하는 색 수
static func colors(n: int) -> int:
	return mini(COLORS_MAX, COLORS_MIN + n / COLORS_EVERY)


# 라운드 시작 시 채워진 줄 수
static func start_rows(n: int) -> int:
	return mini(ROWS_MAX, ROWS_0 + n / ROWS_EVERY)


# 몇 발 쏘면 벌집이 한 줄 내려오는가 (반올림된 정수)
static func shots_per_descend(n: int) -> int:
	return int(round(SHOTS_MIN + (SHOTS_0 - SHOTS_MIN) * pow(SHOTS_DECAY, float(n))))


# 매치 1회로 회복되는 꽃가루
static func recover(popped: int, dropped: int) -> float:
	return RECOVER_PER_POP * float(popped) + RECOVER_PER_DROP * float(dropped)


# ── 공정성 하한 ──
# "이 라운드에서 최소 매치(3개)만 성공시키는 플레이어가 조준에 쓸 수 있는 시간"
# 이 값이 인간 조준 하한(0.25초)보다 작아지면 그 라운드는 클리어 불가능 구간이다.
# ★ 압박 상승이 최대로 걸린 최악 상태로 잰다 — 최악에서 성립해야 공정성 증명이 된다.
static func min_aim_window(n: int) -> float:
	return recover(3, 0) / (POLLEN_MAX / t_budget(n) * ESCALATE_MAX)
