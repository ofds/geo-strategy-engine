extends Node
## Profiling camera driver — for stress-testing streaming only. Leave disabled for normal play.
## Set enabled = true in the inspector to run: pan right -> pan back -> zoom in -> zoom out -> fast pan.
## Use with DEBUG_STREAMING_TIMING / DEBUG_CHUNK_TIMING in chunk_manager/terrain_loader for [TIME] output.

@export var enabled: bool = false

var _camera: Node = null
var _chunk_manager: Node = null
var _phase: int = 0
var _phase_time: float = 0.0

# Phase durations (seconds)
const WAIT_AFTER_LOAD: float = 6.0   # Wait after scene load before moving (let "Dynamic chunk streaming active" print)
const PAN_DURATION: float = 15.0     # Pan right then pan back
const ZOOM_DURATION: float = 5.0     # Zoom in then zoom out
const FAST_PAN_DURATION: float = 10.0
const QUIT_DELAY_AFTER_DONE: float = 2.0  # Seconds to wait after sequence then auto-quit (so log can flush)

# Movement speeds (m/s) — chosen to trigger many chunk loads
const PAN_SPEED: float = 12000.0    # ~12 km/s pan
const FAST_PAN_SPEED: float = 50000.0
const ZOOM_IN_FACTOR: float = 0.5   # Multiply orbit_distance by this when "zooming in"
const ZOOM_OUT_FACTOR: float = 2.0  # Multiply when "zooming out"

var _start_target: Vector3 = Vector3.ZERO
var _start_orbit: float = 50000.0


func _ready() -> void:
	_camera = get_viewport().get_camera_3d()
	_chunk_manager = get_parent().get_node_or_null("ChunkManager")
	if not _camera:
		push_error("ProfilingDriver: No camera found.")
	if not _chunk_manager:
		push_error("ProfilingDriver: ChunkManager not found.")
	if enabled:
		print("[ProfilingDriver] Enabled. Will wait for initial load, then run: pan right -> pan back -> zoom in -> zoom out -> fast pan.")


func _process(delta: float) -> void:
	if not enabled or not _camera or not _chunk_manager:
		return
	if not _chunk_manager.get("initial_load_complete"):
		return

	_phase_time += delta

	# Phase 0: wait a bit after initial load so streaming is active
	if _phase == 0:
		if _phase_time < WAIT_AFTER_LOAD:
			return
		_phase = 1
		_phase_time = 0.0
		_start_target = _camera.get("target_position")
		_start_orbit = _camera.get("target_orbit_distance")
		if _start_target == null:
			_start_target = Vector3.ZERO
		if _start_orbit == null:
			_start_orbit = 50000.0
		print("[ProfilingDriver] Phase 1: Pan right for %.0fs" % PAN_DURATION)

	# Phase 1: pan right (+X)
	if _phase == 1:
		_camera.set("target_position", _start_target + Vector3(PAN_SPEED * _phase_time, 0, 0))
		if _phase_time >= PAN_DURATION:
			_phase = 2
			_phase_time = 0.0
			print("[ProfilingDriver] Phase 2: Pan back for %.0fs" % PAN_DURATION)

	# Phase 2: pan back
	elif _phase == 2:
		var t = _phase_time / PAN_DURATION
		_camera.set("target_position", _start_target + Vector3(PAN_SPEED * PAN_DURATION * (1.0 - t), 0, 0))
		if _phase_time >= PAN_DURATION:
			_phase = 3
			_phase_time = 0.0
			print("[ProfilingDriver] Phase 3: Zoom in for %.0fs" % ZOOM_DURATION)

	# Phase 3: zoom in (reduce orbit distance)
	elif _phase == 3:
		var t = _phase_time / ZOOM_DURATION
		var orbit = lerp(_start_orbit, _start_orbit * ZOOM_IN_FACTOR, t)
		_camera.set("target_orbit_distance", orbit)
		_camera.set("orbit_distance", orbit)
		if _phase_time >= ZOOM_DURATION:
			_phase = 4
			_phase_time = 0.0
			print("[ProfilingDriver] Phase 4: Zoom out for %.0fs" % ZOOM_DURATION)

	# Phase 4: zoom out
	elif _phase == 4:
		var t = _phase_time / ZOOM_DURATION
		var orbit = lerp(_start_orbit * ZOOM_IN_FACTOR, _start_orbit * ZOOM_OUT_FACTOR, t)
		_camera.set("target_orbit_distance", orbit)
		_camera.set("orbit_distance", orbit)
		if _phase_time >= ZOOM_DURATION:
			_phase = 5
			_phase_time = 0.0
			_start_target = _camera.get("target_position")
			if _start_target == null:
				_start_target = Vector3.ZERO
			print("[ProfilingDriver] Phase 5: Fast pan for %.0fs" % FAST_PAN_DURATION)

	# Phase 5: fast pan (mimic speed boost + pan)
	elif _phase == 5:
		_camera.set("target_position", _start_target + Vector3(FAST_PAN_SPEED * _phase_time, 0, 0))
		if _phase_time >= FAST_PAN_DURATION:
			_phase = 6
			_phase_time = 0.0
			print("[ProfilingDriver] Done. Check console for [TIME] and [SPIKE]. Auto-quit in %.1fs." % QUIT_DELAY_AFTER_DONE)

	# Phase 6: wait then quit so the run stops and log can be captured
	elif _phase == 6:
		if _phase_time >= QUIT_DELAY_AFTER_DONE:
			print("[ProfilingDriver] Quitting.")
			get_tree().quit()
