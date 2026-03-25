extends Node2D
class_name SoundPool

@export var pool_size := 8
@export_range(50.0, 2000.0, 10.0) var max_distance := 260.0
@export_range(0.1, 8.0, 0.1) var attenuation := 2.2
@export_range(-40.0, 12.0, 0.5) var default_volume_db := 0.0
var players: Array[AudioStreamPlayer2D] = []

func _init(size := 8):
	pool_size = size

func _ready():
	for i in pool_size:
		var p = AudioStreamPlayer2D.new()
		p.name = "Player%d" % i
		_configure_player(p)
		add_child(p)
		players.append(p)

func _configure_player(player: AudioStreamPlayer2D) -> void:
	player.max_distance = max_distance
	player.attenuation = attenuation
	player.volume_db = default_volume_db

func play_stream(stream: AudioStream):
	if stream == null:
		return
	for p in players:
		if not p.playing:
			p.stream = stream
			p.pitch_scale = randf_range(0.95, 1.05)
			p.play()
			return

	# All busy? Reuse the first
	players[0].stop()
	players[0].stream = stream
	players[0].pitch_scale = randf_range(0.95, 1.05)
	players[0].play()
