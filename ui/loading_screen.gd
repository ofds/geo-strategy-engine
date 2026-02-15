extends CanvasLayer
## Loading Screen - Shows chunk loading progress

var progress_bar: ProgressBar
var status_label: Label
var panel: Panel


func _ready() -> void:
	# Get node references
	panel = $Panel
	progress_bar = $Panel/VBoxContainer/ProgressBar
	status_label = $Panel/VBoxContainer/StatusLabel
	
	# Center the panel
	panel.position = Vector2(
		(get_viewport().get_visible_rect().size.x - panel.size.x) / 2,
		(get_viewport().get_visible_rect().size.y - panel.size.y) / 2
	)
	show_loading()


func show_loading() -> void:
	visible = true
	if progress_bar:
		progress_bar.value = 0
	if status_label:
		status_label.text = "Loading terrain chunks..."


func update_progress(current: int, total: int, chunk_name: String) -> void:
	if not progress_bar or not status_label:
		return
	
	progress_bar.max_value = total
	progress_bar.value = current
	status_label.text = "Loading %s (%d/%d)" % [chunk_name, current, total]


func hide_loading() -> void:
	visible = false
