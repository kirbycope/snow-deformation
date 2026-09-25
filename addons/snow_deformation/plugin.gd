# Copyright (c) 2026 Antigravity Contributors
# SPDX-License-Identifier: MIT
@tool
extends EditorPlugin
## Puts the snow nodes in the Create New Node dialog.
##
## Every preload here is written relative to this file, which is exactly the kind a search for "res://"
## never finds, so tests/test_editor_plugin.gd checks each one resolves.


func _enter_tree() -> void:
	add_custom_type(
		"SnowDeformation",
		"Node3D",
		preload("snow_deformation.gd"),
		preload("assets/icons/snow_deformation_icon.svg")
	)
	add_custom_type(
		"FootStamper",
		"Node",
		preload("foot_stamper.gd"),
		preload("assets/icons/foot_stamper_icon.svg")
	)
	add_custom_type(
		"BladeStamper",
		"Node",
		preload("blade_stamper.gd"),
		preload("assets/icons/blade_stamper_icon.svg")
	)


func _exit_tree() -> void:
	remove_custom_type("SnowDeformation")
	remove_custom_type("FootStamper")
	remove_custom_type("BladeStamper")
