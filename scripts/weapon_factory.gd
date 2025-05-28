extends Node

func spawn_weapon_instance(weapon: Weapon) -> WeaponInstance:
	var instance = weapon.weapon_scene.instantiate() as WeaponInstance
	instance.set_weapon_data(weapon)
	return instance

func spawn_pickup(weapon: Weapon, position: Vector2) -> WeaponPickup:
	var pickup = weapon.pickup_scene.instantiate() as WeaponPickup
	pickup.set_weapon_data(weapon)
	pickup.global_position = position
	return pickup
