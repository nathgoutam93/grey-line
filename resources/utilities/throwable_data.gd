extends EquipmentData
class_name ThrowableData

@export var projectile_scene: PackedScene
@export var detonate_effect_scene: PackedScene
@export var throw_speed: float = 700.0
@export var throw_torque: float = 8.0
@export var throw_release_time: float = 0.2
@export var aim_convergence_distance: float = 700.0
@export var max_travel_distance: float = 900.0
@export var arc_peak_height: float = 18.0
@export var fuse_time: float = 1.6
@export var flash_duration: float = 2.0
@export var flash_radius: float = 900.0
@export_range(0.0, 180.0, 1.0) var flash_angle_deg: float = 70.0
@export_range(0.0, 1.0, 0.05) var flash_max_alpha: float = 0.95
@export var smoke_duration: float = 5.0
@export var explosion_radius: float = 320.0
@export var explosion_force: float = 680.0
@export var explosion_max_damage: int = 95
@export var explosion_min_damage: int = 15
@export var use_cooldown: float = 1.0
@export var consume_on_use: bool = false
@export var max_charges: int = 1
