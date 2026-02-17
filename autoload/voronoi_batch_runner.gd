extends Node
## Autoload: F9 runs Voronoi batch; --voronoi_batch (or --feature voronoi_batch) auto-runs then exits.
## No manual scene setup: F5 → F9 to run batch in-game.

const BATCH_SCRIPT := preload("res://tools/generate_voronoi_batch.gd")

func _ready() -> void:
	if _wants_batch_from_cmdline():
		_run_batch()
		get_tree().quit()


func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key := event as InputEventKey
		if key.pressed and key.keycode == KEY_F9:
			# Defer so we run in the next frame when main RenderingDevice is ready for submit/sync
			call_deferred("_run_batch")


func _wants_batch_from_cmdline() -> bool:
	var args: PackedStringArray = OS.get_cmdline_args()
	for i in range(args.size()):
		if args[i] == "--voronoi_batch":
			return true
		if args[i] == "--feature" and i + 1 < args.size() and args[i + 1] == "voronoi_batch":
			return true
	return false


func _run_batch() -> void:
	# Add batch node; its _ready() defers generate_all_chunks so GPU runs when main device is active
	var runner := Node.new()
	runner.set_script(BATCH_SCRIPT)
	add_child(runner)
	print("VoronoiBatchRunner: Batch started (F9). See output above.")
