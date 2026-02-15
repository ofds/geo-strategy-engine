extends Label
## FPS Counter - Displays current FPS and draw calls in top-left corner

func _process(delta: float) -> void:
	var frame_ms = delta * 1000.0
	if frame_ms > 33.0:
		print("[SPIKE] Frame time: %dms (below 30fps)" % int(frame_ms))
	var fps = Engine.get_frames_per_second()
	var draw_calls = RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
	text = "FPS: %d\nDraw Calls: %d" % [fps, draw_calls]
