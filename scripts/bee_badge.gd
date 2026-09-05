# 메뉴 마스코트 — 제목 위의 아기 벌. 날갯짓만 한다.
#
# 메뉴 뒤에 게임 화면을 그대로 깔았더니 발사대 벌이 리더보드 글자와 겹쳤다.
# 마스코트는 UI 흐름 안에 두고, 판의 발사대와는 같은 그림 함수(Palette.draw_bee)만 공유한다.
extends Control

var _t := 0.0


func _ready() -> void:
	custom_minimum_size = Vector2(0, 150)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(true)


func _process(delta: float) -> void:
	_t += delta
	queue_redraw()


func _draw() -> void:
	var c := Vector2(size.x * 0.5, size.y * 0.5 + sin(_t * 2.2) * 6.0)
	Palette.draw_bee(self, c, 44.0, Vector2(sin(_t * 0.9) * 0.6, -1.0), sin(_t * 18.0) * 0.35)
