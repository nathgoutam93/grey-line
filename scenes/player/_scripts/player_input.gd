extends MultiplayerSynchronizer
class_name PlayerInput

@export var input_vector := Vector2()
@export var mouse_pos := Vector2()

@export var player: PlayerController

func set_authority(peer_id: int):
    set_multiplayer_authority(peer_id)
    if peer_id == multiplayer.get_unique_id():
        set_process(true)

func _ready() -> void:
    set_process(false)

func _process(_delta: float) -> void:
    mouse_pos = player.get_global_mouse_position()
    
    input_vector = Vector2(
        Input.get_action_strength("move_right") - Input.get_action_strength("move_left"),
        Input.get_action_strength("move_down") - Input.get_action_strength("move_up")
    ).normalized()

    if Input.is_action_just_pressed("slow_walk"):
        if multiplayer.is_server():
            player.request_start_slow_walk()
        else:
            request_start_slow_walk.rpc_id(1)

    if Input.is_action_just_released("slow_walk"):
        if multiplayer.is_server():
            player.request_stop_slow_walk()
        else:
            request_stop_slow_walk.rpc_id(1)

    if Input.is_action_just_pressed("shoot"):
        if multiplayer.is_server():
            player.request_start_fire()
        else:
            request_start_fire.rpc_id(1)

    if Input.is_action_just_released("shoot"):
        if multiplayer.is_server():
           player.request_stop_fire()
        else:
           request_stop_fire.rpc_id(1)

    if Input.is_action_just_pressed("reload"):
        if multiplayer.is_server():
            player.request_reload()
        else:
            request_reload.rpc_id(1)

    if Input.is_action_just_pressed("weapon_switch"):
        if multiplayer.is_server():
            player.request_switch_weapon_next()
        else:
            request_switch_weapon_next.rpc_id(1)

    if Input.is_action_just_pressed("drop_weapon"):
        if multiplayer.is_server():
            player.request_drop_weapon()
        else:
            request_drop_weapon.rpc_id(1)

@rpc("authority", "reliable")
func request_start_slow_walk():
    player.request_start_slow_walk()

@rpc("authority", "reliable")
func request_stop_slow_walk():
    player.request_stop_slow_walk()

@rpc("authority", "reliable")
func request_start_fire():
    player.request_start_fire()
	
@rpc("authority", "reliable")
func request_stop_fire():
    player.request_stop_fire()

@rpc("authority", "reliable")
func request_reload():
    player.request_reload()

@rpc("authority", "reliable")
func request_switch_weapon_next():
    player.request_switch_weapon_next()

@rpc("authority", "reliable")
func request_drop_weapon():
    player.request_drop_weapon()
