extends "res://tests/net/net_test_base.gd"

## Owner prediction + authoritative ammo. The client fires the rifle (held),
## reloads, taps the pistol, fires the rifle again, then has its ammo and slot
## deliberately desynced. Checks: every first shot happens within 1 tick of
## pressing fire, ammo ends equal to the server's, and both desyncs are
## corrected from snapshots.

const MAX_FIRE_LATENCY_TICKS := 1

var _press_tick := -1
var _mag_at_press := -1
var _waiting_for_shot := false
var _latencies: Array[int] = []

func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if role != "client" or not _waiting_for_shot:
		return
	# Measured in network ticks: physics frames and ticks can drift apart by
	# one (the tick accumulator can skip a physics frame, then emit two).
	var mag := _current_mag()
	if mag >= 0 and mag < _mag_at_press:
		_latencies.append(NetworkTick.tick - _press_tick)
		_waiting_for_shot = false
	elif NetworkTick.tick - _press_tick > 60:
		_latencies.append(999)
		_waiting_for_shot = false

func _current_mag() -> int:
	var me := local_player()
	var weapon := me.get_current_equipment() as WeaponInstance if me else null
	return weapon.ammo_in_mag if weapon else -1

func _fire(seconds: float) -> void:
	_press_tick = NetworkTick.tick
	_mag_at_press = _current_mag()
	_waiting_for_shot = true
	await tap("shoot", seconds)

func run_client() -> void:
	var me := local_player()
	var equipment := me.equipment_manager
	await tap("primary")
	await hold(1.5)
	await _fire(1.0)
	await hold(0.6)
	await tap("reload")
	await hold(3.5)
	await tap("secondary")
	await hold(1.5)
	for i in range(3):
		await _fire(0.08)
		await hold(0.5)
	await tap("primary")
	await hold(1.5)
	await _fire(0.4)
	await hold(1.0)

	var settled := equipment.capture_weapon_ammo()
	var rifle := equipment.get_item_in_slot(EquipmentManager.EquipmentSlot.PRIMARY) as WeaponInstance
	rifle.ammo_in_mag = 3
	rifle.ammo_reserve = 999
	await hold(0.5)
	var after_ammo_desync := equipment.capture_weapon_ammo()

	equipment.equip_slot(EquipmentManager.EquipmentSlot.MELEE) # local only, no input sent
	await hold(1.0)

	send("report", {
		"latencies": _latencies,
		"ammo": equipment.capture_weapon_ammo(),
		"slot": equipment.get_target_slot(),
		"settled_ammo": settled,
		"after_ammo_desync": after_ammo_desync,
	})

func run_host() -> void:
	var report: Variant = await wait_for("report", 60.0)
	if report == null:
		results.fail("client_report", "no report from the client")
		return
	var latencies: Array = report["latencies"]
	var worst := 0
	for l in latencies:
		worst = maxi(worst, int(l))
	check("first_shot_within_one_tick", latencies.size() == 5 and worst <= MAX_FIRE_LATENCY_TICKS, "%d shots measured, worst %d ticks" % [latencies.size(), worst])

	var server_equipment := player(client_peer()).equipment_manager
	var server_ammo := server_equipment.capture_weapon_ammo()
	check("ammo_matches_server", report["ammo"] == server_ammo, "client %s, server %s" % [report["ammo"], server_ammo])
	check("injected_ammo_desync_corrected", report["after_ammo_desync"] == report["settled_ammo"], "after desync %s, before %s" % [report["after_ammo_desync"], report["settled_ammo"]])
	var server_slot := server_equipment.get_target_slot()
	check("local_only_switch_corrected", int(report["slot"]) == server_slot, "client slot %d, server slot %d" % [int(report["slot"]), server_slot])
