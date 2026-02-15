extends Label
## FPS Counter - Displays current FPS, rolling average, 1% low, and draw calls

const HISTORY_SIZE: int = 100
const ROLLING_AVG_SIZE: int = 60
var _delta_history: Array = []
var _perf_warning_cooldown: float = 0.0
var _history_cleared_after_load: bool = false

func _process(delta: float) -> void:
	var cm = get_tree().current_scene.get_node_or_null("ChunkManager")
	if cm and cm.has_method("has_initial_load_completed") and cm.has_initial_load_completed() and not _history_cleared_after_load:
		_delta_history.clear()
		_history_cleared_after_load = true
	_delta_history.append(delta)
	if _delta_history.size() > HISTORY_SIZE:
		_delta_history.remove_at(0)
	var fps = Engine.get_frames_per_second()
	var draw_calls = RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
	var avg_fps_str = "--"
	var low_1pct_str = "--"
	if _delta_history.size() >= ROLLING_AVG_SIZE:
		var sum = 0.0
		var start = _delta_history.size() - ROLLING_AVG_SIZE
		for i in range(start, _delta_history.size()):
			sum += _delta_history[i]
		avg_fps_str = str(int(ROLLING_AVG_SIZE / sum))
	if _delta_history.size() >= HISTORY_SIZE:
		var max_delta = 0.0
		for d in _delta_history:
			if d > max_delta:
				max_delta = d
		var low_1pct = 1.0 / max_delta
		low_1pct_str = str(int(low_1pct))
		# Warning if 1% low drops below 60 (throttled)
		_perf_warning_cooldown -= delta
		if low_1pct < 60.0 and _perf_warning_cooldown <= 0.0:
			_perf_warning_cooldown = 2.0
			var phase_b_ms = 0.0
			if cm and "_last_phase_b_ms" in cm:
				phase_b_ms = cm._last_phase_b_ms
			print("[PERF] 1%% low: %d FPS (Phase B: %dms)" % [int(low_1pct), int(phase_b_ms)])
	text = "FPS: %d (avg: %s, 1%% low: %s)\nDraw Calls: %d" % [fps, avg_fps_str, low_1pct_str, draw_calls]
