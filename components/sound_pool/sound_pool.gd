extends Node2D
class_name SoundPool

@export var pool_size := 8
var players: Array[AudioStreamPlayer2D] = []

func _init(size := 8):
	pool_size = size

func _ready():
	for i in pool_size:
		var p = AudioStreamPlayer2D.new()
		p.name = "Player%d" % i
		p.max_distance = 500
		add_child(p)
		players.append(p)

func play_stream(stream: AudioStream):
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
