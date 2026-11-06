class_name UITheme
extends RefCounted
## Общий стиль интерфейса: крупные кнопки под палец, скруглённые углы, тёмные панели.
## Тема (Theme) в Godot — это набор правил «как выглядят кнопки, надписи, поля ввода».
## Её назначают корневому узлу меню — и все кнопки внутри выглядят одинаково.

const ACCENT := Color(0.40, 0.68, 0.30)   # травяной зелёный
const BUTTON := Color(0.20, 0.25, 0.31)
const PANEL := Color(0.09, 0.11, 0.15, 0.94)
const TEXT := Color(0.94, 0.95, 0.96)
const TEXT_DIM := Color(0.68, 0.72, 0.78)


static func create() -> Theme:
	var t := Theme.new()
	t.default_font_size = 26

	# --- Кнопки ---
	t.set_stylebox("normal", "Button", _box(BUTTON, 10, 14))
	t.set_stylebox("hover", "Button", _box(BUTTON.lightened(0.12), 10, 14))
	t.set_stylebox("pressed", "Button", _box(ACCENT.darkened(0.15), 10, 14))
	t.set_stylebox("hover_pressed", "Button", _box(ACCENT, 10, 14))
	t.set_stylebox("disabled", "Button", _box(BUTTON.darkened(0.35), 10, 14))
	t.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	t.set_color("font_color", "Button", TEXT)
	t.set_color("font_hover_color", "Button", TEXT)
	t.set_color("font_pressed_color", "Button", TEXT)
	t.set_color("font_hover_pressed_color", "Button", TEXT)
	t.set_color("font_disabled_color", "Button", TEXT_DIM.darkened(0.3))

	# --- Панели ---
	var panel := _box(PANEL, 16, 28)
	t.set_stylebox("panel", "PanelContainer", panel)

	# --- Надписи ---
	t.set_color("font_color", "Label", TEXT)

	# --- Поля ввода ---
	var edit := _box(Color(0.05, 0.06, 0.08), 8, 12)
	edit.border_color = BUTTON.lightened(0.2)
	edit.set_border_width_all(2)
	t.set_stylebox("normal", "LineEdit", edit)
	var edit_focus := edit.duplicate() as StyleBoxFlat
	edit_focus.border_color = ACCENT
	t.set_stylebox("focus", "LineEdit", edit_focus)
	t.set_color("font_color", "LineEdit", TEXT)
	t.set_color("font_placeholder_color", "LineEdit", TEXT_DIM.darkened(0.2))

	# --- Ползунки: толще и с крупной ручкой, чтобы удобно тянуть пальцем ---
	var track := _box(Color(0.05, 0.06, 0.08), 6, 0)
	track.content_margin_top = 6
	track.content_margin_bottom = 6
	t.set_stylebox("slider", "HSlider", track)
	var filled := _box(ACCENT.darkened(0.1), 6, 0)
	filled.content_margin_top = 6
	filled.content_margin_bottom = 6
	t.set_stylebox("grabber_area", "HSlider", filled)
	t.set_stylebox("grabber_area_highlight", "HSlider", filled)
	var knob := _circle_texture(34, TEXT)
	t.set_icon("grabber", "HSlider", knob)
	t.set_icon("grabber_highlight", "HSlider", knob)

	# --- Прокрутка списка ---
	t.set_stylebox("panel", "ScrollContainer", StyleBoxEmpty.new())
	return t


static func _box(color: Color, radius: int, margin: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = color
	s.set_corner_radius_all(radius)
	s.content_margin_left = margin * 1.6
	s.content_margin_right = margin * 1.6
	s.content_margin_top = margin
	s.content_margin_bottom = margin
	return s


static func _circle_texture(size: int, color: Color) -> ImageTexture:
	var img := Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
	var r := size / 2.0
	for y in size:
		for x in size:
			var d := Vector2(x + 0.5 - r, y + 0.5 - r).length()
			var a := clampf(r - d, 0.0, 1.0) # сглаженный край
			img.set_pixel(x, y, Color(color.r, color.g, color.b, a))
	return ImageTexture.create_from_image(img)


## Быстро создать кнопку с текстом и действием.
static func button(text: String, on_press: Callable, min_width := 360) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(min_width, 64)
	if on_press.is_valid():
		b.pressed.connect(on_press)
	return b


static func label(text: String, font_size := 26, color := TEXT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	return l
