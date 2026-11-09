extends RefCounted
class_name LeaveMatchDialog

## Confirmation before leaving a running match. Confirming forfeits the
## player's slot (MultiplayerSession.leave_match): unlike a crash or a lost
## connection, there is no rejoin afterwards.

const TEXT := "Leave the match?\nYou will not be able to rejoin it."

static func confirm(parent: Node, on_confirm: Callable) -> ConfirmationDialog:
	if not is_instance_valid(parent) or not parent.is_inside_tree():
		return null
	var dialog := ConfirmationDialog.new()
	dialog.name = "LeaveMatchDialog"
	dialog.title = "Leave match"
	dialog.dialog_text = TEXT
	dialog.ok_button_text = "Leave"
	dialog.cancel_button_text = "Stay"
	dialog.exclusive = true
	dialog.confirmed.connect(on_confirm)
	dialog.visibility_changed.connect(func():
		if not dialog.visible:
			dialog.queue_free())
	parent.add_child(dialog)
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	dialog.popup_centered()
	return dialog
