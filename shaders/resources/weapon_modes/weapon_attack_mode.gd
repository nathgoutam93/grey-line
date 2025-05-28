extends Resource
class_name WeaponAttackMode

@export var name: String
@export var cooldown: float = 0.3 # cooldown after a shot
@export var burst_count: int = 3
@export var is_auto: bool = false

@export var sound: AudioStream
@export var animation: String = ""