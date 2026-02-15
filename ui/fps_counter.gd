extends Label
## FPS Counter - Displays current FPS and draw calls in top-left corner

func _process(_delta: float) -> void:
	var fps = Engine.get_frames_per_second()
	var draw_calls = RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
	text = "FPS: %d\nDraw Calls: %d" % [fps, draw_calls]
