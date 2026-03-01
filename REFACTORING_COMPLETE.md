The refactor introduces gameplay-breaking regressions in core inventory flow: pickups can become no-ops with the new manager,
dropping does not execute proper drop lifecycle, and backward compatibility in WeaponManager pickup is broken by uninitialized
weapon instances. There is also a behavior regression in post-equip auto-reload.

Full review comments:

- [P1] Initialize picked weapon instance with weapon data — /Users/nathgoutam93/Documents/GODOT/GreyLine/components/weapon_manager/
  weapon_manager.gd:110-114
  The new pickup_weapon flow instantiates wi but no longer calls wi.set_weapon_data(...), so wi.equipment_data/data stays null. Any
  later access like current_weapon.data.camera_shake_strength, animations, or reload logic can fail when a picked-up weapon is
  equipped. This breaks the stated backward compatibility path for scenes still using WeaponManager.
- [P1] Fall back when selected manager cannot handle pickup — /Users/nathgoutam93/Documents/GODOT/GreyLine/scenes/player/\_scripts/
  player_controller.gd:411-416
  When equipment_manager exists (now true in player.tscn), \_remote_pickup always selects it first, but EquipmentManager does not
  implement pickup_weapon. Because the condition requires mgr.has_method("pickup_weapon"), the pickup request becomes a silent no-
  op and players cannot pick up weapons in the migrated setup.
- [P1] Drop current equipment via drop lifecycle — /Users/nathgoutam93/Documents/GODOT/GreyLine/components/equipment_manager/
  equipment_manager.gd:146-151
  drop_current_item only clears references and switches slots; it never unequips/frees the old node or spawns its pickup. In
  practice, dropping with EquipmentManager can leave the old item attached and effectively delete it from inventory without
  creating a world pickup, which is a gameplay regression from WeaponManager.drop_weapon.
- [P2] Preserve auto-reload after equip delay — /Users/nathgoutam93/Documents/GODOT/GreyLine/scenes/weapon/weapon_instance.gd:179-
  183
  Auto-reload now only runs when \_equip_ticks_remaining <= 0 immediately after super.equip(). For weapons with nonzero equip_time,
  the reload that previously triggered when equip finished no longer happens, so equipping an empty weapon leaves it idle until
  manual reload. This changes existing weapon behavior after the refactor.
