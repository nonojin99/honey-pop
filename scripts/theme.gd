# 팔레트 · 구슬 모양 — 싱글과 대결이 같은 걸 쓴다.
#
# 컨셉: 밤의 벌집. 따뜻한 어두운 바탕(꿀빛 갈색)에 구슬만 빛난다.
# 팔레트를 3~5색으로 묶고 구슬만 채도를 높여서, 어디가 조작 대상인지 색으로 구분되게 했다.
#
# 구슬은 무늬 없이 **명암만으로** 입체를 만든다. 셰이더 없이 원을 여러 겹 겹쳐 그러데이션을
# 흉내 내므로 웹(gl_compatibility) 빌드에서도 그대로 나온다.
class_name Palette
extends RefCounted

# 바탕 (위 → 아래 그러데이션)
const BG_TOP := Color("140d04")
const BG_BOT := Color("2a1c09")
const PANEL := Color("00000055")

const INK := Color("fff3d6")          # 본문 글씨
const INK_DIM := Color("c2a878")      # 보조 글씨 — 바탕에 묻히지 않을 만큼만 낮춘 명도
const GOLD := Color("ffb627")         # 강조 (점수·꽃가루)
const DANGER := Color("ff5d5d")

# 구슬 6색. 어두운 바탕 위에서 서로 확실히 갈리는 색상환 간격으로 골랐다
const BUBBLE := [
	Color("ffc23c"),   # 0 꿀
	Color("ff5d73"),   # 1 산딸기
	Color("4ecb71"),   # 2 잎
	Color("4ea8de"),   # 3 하늘
	Color("b07cff"),   # 4 라벤더
	Color("fff1d0"),   # 5 크림
]

static func bubble_color(i: int) -> Color:
	return BUBBLE[posmod(i, BUBBLE.size())]


# 구슬 하나를 그린다. 위에서 빛이 오는 구(球)로 보이게 명암을 겹쳐 쌓는다.
#
# 셰이더를 쓰지 않는 이유는 웹 빌드 호환이다(gl_compatibility). 대신 원을 위쪽으로 조금씩
# 밀며 어두운 색 → 밝은 색으로 겹쳐 그리면 구형 그러데이션이 된다.
static func draw_bubble(ci: CanvasItem, center: Vector2, radius: float, color_index: int, alpha: float = 1.0) -> void:
	var base := bubble_color(color_index)
	var shade := base.darkened(0.42)
	var lit := base.lightened(0.34)
	shade.a = alpha
	lit.a = alpha

	# 접지 그림자 — 구슬이 판에 얹혀 있게 보이는 최소 조건
	ci.draw_circle(center + Vector2(0, radius * 0.10), radius, Color(0, 0, 0, 0.34 * alpha))

	# 어두운 아래쪽에서 밝은 위쪽으로 원을 겹쳐 올린다
	var steps := 7
	for i in steps:
		var t := float(i) / float(steps - 1)
		var col := shade.lerp(lit, t)
		col.a = alpha
		var rr := radius * (0.95 - 0.30 * t)
		var off := Vector2(-radius * 0.10 * t, -radius * 0.24 * t)
		ci.draw_circle(center + off, rr, col)

	# 아래쪽 반사광 — 이게 있어야 납작한 원이 아니라 공으로 읽힌다
	var bounce := base.lightened(0.18)
	bounce.a = 0.34 * alpha
	ci.draw_arc(center, radius * 0.80, deg_to_rad(35.0), deg_to_rad(145.0), 18, bounce, radius * 0.16)

	# 하이라이트 — 광원 쪽 작은 점
	ci.draw_circle(center - Vector2(radius * 0.30, radius * 0.36), radius * 0.20, Color(1, 1, 1, 0.62 * alpha))
	ci.draw_circle(center - Vector2(radius * 0.34, radius * 0.42), radius * 0.10, Color(1, 1, 1, 0.85 * alpha))


# 아기 벌 — 이 게임의 감성 스킨. 메뉴에서는 마스코트로, 판에서는 발사대로 같은 그림을 쓴다.
#
# 구슬과 같은 방식으로 명암을 쌓아 공처럼 보이게 한다. 줄무늬는 네모로 얹으면 딱지처럼
# 납작해 보이므로, 구의 단면 폭(√(r²-dy²))을 따라 휘어지는 띠로 그린다.
# look 은 바라보는 방향(정규화), flap 은 날갯짓 위상.
static func draw_bee(ci: CanvasItem, at: Vector2, rad: float, look: Vector2, flap: float) -> void:
	var body := Color("f5b027")
	var shade := body.darkened(0.45)
	var lit := body.lightened(0.38)
	var stripe := Color("3a2408")

	# 날개는 몸 뒤에. 세로로 서면 토끼 귀처럼 보이므로, 납작하게 눌러 바깥으로 길게 뻗는다
	# (정원 → 살짝 기운 타원 → 지금의 납작한 타원 순으로 고쳤다. 눕히는 정도가 관건이었다)
	for sgn in [-1.0, 1.0]:
		var wing := at + Vector2(float(sgn) * rad * 0.52, -rad * 0.62)
		var tilt: float = float(sgn) * (0.20 + flap * 0.5)
		ci.draw_set_transform(wing, tilt, Vector2(2.05, 0.42))
		ci.draw_circle(Vector2(float(sgn) * rad * 0.62, 0.0), rad * 0.66, Color(0.88, 0.95, 1.0, 0.24))
		ci.draw_arc(Vector2(float(sgn) * rad * 0.62, 0.0), rad * 0.66, 0.0, TAU, 24, Color(1, 1, 1, 0.32), rad * 0.05)
		ci.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	# 접지 그림자
	ci.draw_circle(at + Vector2(0, rad * 0.14), rad * 1.12, Color(0, 0, 0, 0.34))

	# 몸통 — 아래 어둡고 위 밝게 원을 겹쳐 구를 만든다
	var steps := 8
	for i in steps:
		var t := float(i) / float(steps - 1)
		ci.draw_circle(at + Vector2(-rad * 0.10 * t, -rad * 0.26 * t),
			rad * (1.05 - 0.32 * t), shade.lerp(lit, t))

	# 줄무늬 — 구의 단면을 따라 휘어진다
	_sphere_band(ci, at, rad * 1.02, -rad * 0.06, rad * 0.16, stripe)
	_sphere_band(ci, at, rad * 1.02, rad * 0.40, rad * 0.62, stripe)

	# 아래쪽 반사광
	ci.draw_arc(at, rad * 0.86, deg_to_rad(30.0), deg_to_rad(150.0), 18,
		Color(body.lightened(0.25), 0.30), rad * 0.14)

	# 눈 — 바라보는 쪽으로 아주 조금 쏠린다(살아 있다는 느낌은 여기서 나온다)
	var gaze := look * rad * 0.10
	for sgn2 in [-1.0, 1.0]:
		var eye := at + Vector2(sgn2 * rad * 0.34, -rad * 0.46) + gaze
		ci.draw_circle(eye, rad * 0.17, Color("241505"))
		ci.draw_circle(eye - Vector2(rad * 0.05, rad * 0.06), rad * 0.06, Color(1, 1, 1, 0.85))

	# 몸통 하이라이트
	ci.draw_circle(at - Vector2(rad * 0.36, rad * 0.62), rad * 0.16, Color(1, 1, 1, 0.40))


# 구의 단면 폭을 따라 휘어지는 가로 띠. y0..y1 은 중심 기준 세로 범위(픽셀).
# 네모로 그리면 종이 딱지처럼 납작해 보인다 — 이 한 가지가 입체감을 크게 가른다.
static func _sphere_band(ci: CanvasItem, c: Vector2, r: float, y0: float, y1: float, col: Color) -> void:
	var steps := 12
	var top: PackedVector2Array = PackedVector2Array()
	var bottom: PackedVector2Array = PackedVector2Array()
	for i in steps + 1:
		var t := float(i) / float(steps)
		var yy: float = lerpf(y0, y1, t)
		var hw: float = sqrt(maxf(0.0, r * r - yy * yy))
		top.append(c + Vector2(-hw, yy))
		bottom.append(c + Vector2(hw, yy))
	var poly := PackedVector2Array()
	for p in top:
		poly.append(p)
	for i in range(bottom.size() - 1, -1, -1):
		poly.append(bottom[i])
	if poly.size() >= 3:
		ci.draw_colored_polygon(poly, col)
