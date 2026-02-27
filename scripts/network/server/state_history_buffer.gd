extends RefCounted
class_name StateHistoryBuffer

var max_history := 60
var _entries: Array = []

func configure(history_ticks: int) -> void:
	max_history = max(history_ticks, 1)

func store(tick: int, transform_value: Transform2D) -> void:
	_entries.append({"tick": tick, "transform": transform_value})
	while _entries.size() > max_history:
		_entries.pop_front()

func get_transform_for_tick(tick: int) -> Variant:
	for i in range(_entries.size() - 1, -1, -1):
		var entry: Dictionary = _entries[i]
		if int(entry.get("tick", -1)) <= tick:
			return entry.get("transform")
	return null
