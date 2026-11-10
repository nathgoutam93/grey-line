"""Models GreyLine's house furniture in Blender and renders the 2D art.

For each piece it writes, into assets/props/furniture/<name>/:
  top.png     straight-down orthographic render (the prop's sprite / roof)
  slices.png  SLICE_COUNT renders side by side, lowest first; slice i shows
              everything up to (i + 1) / SLICE_COUNT of the piece's height,
              for a PerspectiveProfile of kind SLICES.

Run from the repository root (Blender 4.2+ / 5.x):
  /Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup \
      --python tools/blender/furniture.py -- [names...]

Conventions: 1 m = PIXELS_PER_METER px in the renders (the prop scenes scale
them by 0.5, so 64 px per metre in the world). +Y in Blender is up (north) in
the image. Pieces are built around the origin with their floor at z = 0.
"""

import math
import os
import sys

import bpy
import numpy as np

PIXELS_PER_METER = 128
SLICE_COUNT = 10
CAMERA_Z = 10.0
OUT_DIR = os.path.join(os.getcwd(), "assets", "props", "furniture")

# --- palette -----------------------------------------------------------------

FABRIC = (0.22, 0.27, 0.34)
FABRIC_LIGHT = (0.28, 0.34, 0.42)
WOOD = (0.36, 0.24, 0.15)
WOOD_LIGHT = (0.46, 0.32, 0.20)
WOOD_DARK = (0.18, 0.15, 0.13)
SCREEN = (0.03, 0.035, 0.04)
CABINET = (0.80, 0.78, 0.74)
STONE = (0.12, 0.13, 0.14)
STEEL = (0.55, 0.57, 0.60)
PAPER = (0.85, 0.80, 0.68)
ACCENT = (0.62, 0.25, 0.20)

_materials = {}


def material(color, roughness=0.6, metallic=0.0):
    key = (color, roughness, metallic)
    if key not in _materials:
        mat = bpy.data.materials.new("m%d" % len(_materials))
        mat.use_nodes = True
        bsdf = mat.node_tree.nodes.get("Principled BSDF")
        bsdf.inputs["Base Color"].default_value = (*color, 1.0)
        bsdf.inputs["Roughness"].default_value = roughness
        bsdf.inputs["Metallic"].default_value = metallic
        _materials[key] = mat
    return _materials[key]


def box(size, center_xy, z0, color, bevel=0.012, roughness=0.6, metallic=0.0):
    """Box of `size` (x, y, z) metres centred on `center_xy`, standing on z0."""
    sx, sy, sz = size
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=(center_xy[0], center_xy[1], z0 + sz / 2.0))
    obj = bpy.context.active_object
    obj.scale = (sx, sy, sz)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    if bevel > 0.0:
        mod = obj.modifiers.new("bevel", "BEVEL")
        mod.width = min(bevel, sx / 3.0, sy / 3.0, sz / 3.0)
        mod.segments = 2
    obj.data.materials.append(material(color, roughness, metallic))
    return obj


def cylinder(radius, depth, center_xy, z0, color, roughness=0.5, metallic=0.0):
    bpy.ops.mesh.primitive_cylinder_add(radius=radius, depth=depth, vertices=24, location=(center_xy[0], center_xy[1], z0 + depth / 2.0))
    obj = bpy.context.active_object
    obj.data.materials.append(material(color, roughness, metallic))
    return obj


# --- pieces (width x depth in metres; north = +Y) -------------------------------

def sofa():
    """Three-seat sofa; back against a north wall, seats face south."""
    box((2.0, 0.9, 0.40), (0, 0), 0.0, FABRIC, bevel=0.04)
    box((1.70, 0.24, 0.48), (0, 0.31), 0.38, FABRIC, bevel=0.06)
    for x in (-0.925, 0.925):
        box((0.15, 0.9, 0.62), (x, 0), 0.0, FABRIC, bevel=0.05)
    for x in (-0.57, 0.0, 0.57):
        box((0.55, 0.60, 0.13), (x, -0.10), 0.40, FABRIC_LIGHT, bevel=0.05)
    box((0.36, 0.14, 0.30), (-0.62, 0.15), 0.52, ACCENT, bevel=0.06)
    return (2.0, 0.9)


def coffee_table():
    box((1.1, 0.6, 0.05), (0, 0), 0.40, WOOD, bevel=0.01)
    for x in (-0.5, 0.5):
        for y in (-0.25, 0.25):
            box((0.05, 0.05, 0.40), (x, y), 0.0, WOOD_DARK, bevel=0.0)
    box((0.30, 0.22, 0.03), (-0.22, 0.05), 0.45, PAPER, bevel=0.004)
    cylinder(0.05, 0.10, (0.28, -0.08), 0.45, ACCENT)
    return (1.1, 0.6)


def tv_stand():
    """Low cabinet with a TV; back against a south wall, screen faces north."""
    box((1.6, 0.45, 0.50), (0, 0), 0.0, WOOD_DARK, bevel=0.015)
    box((0.30, 0.20, 0.04), (0, -0.05), 0.50, STEEL, bevel=0.005, metallic=0.6, roughness=0.3)
    box((1.30, 0.06, 0.76), (0, -0.05), 0.56, SCREEN, bevel=0.01, roughness=0.15)
    box((0.22, 0.14, 0.10), (0.6, 0.08), 0.50, STEEL, bevel=0.01, metallic=0.5)
    return (1.6, 0.45)


def dining_set():
    """Table for six: two chairs per long side and one at each end."""
    box((1.6, 0.9, 0.04), (0, 0), 0.72, WOOD_LIGHT, bevel=0.01)
    for x in (-0.72, 0.72):
        for y in (-0.37, 0.37):
            box((0.06, 0.06, 0.72), (x, y), 0.0, WOOD, bevel=0.0)
    chairs = [((-0.45, 0.62), "n"), ((0.45, 0.62), "n"), ((-0.45, -0.62), "s"), ((0.45, -0.62), "s"), ((-0.98, 0), "w"), ((0.98, 0), "e")]
    for (x, y), side in chairs:
        box((0.42, 0.42, 0.05), (x, y), 0.43, WOOD, bevel=0.01)
        for lx in (-0.18, 0.18):
            for ly in (-0.18, 0.18):
                box((0.035, 0.035, 0.43), (x + lx, y + ly), 0.0, WOOD_DARK, bevel=0.0)
        if side in ("n", "s"):
            back_y = y + (0.19 if side == "n" else -0.19)
            box((0.42, 0.04, 0.48), (x, back_y), 0.48, WOOD, bevel=0.01)
        else:
            back_x = x + (0.19 if side == "e" else -0.19)
            box((0.04, 0.42, 0.48), (back_x, y), 0.48, WOOD, bevel=0.01)
    cylinder(0.12, 0.02, (0, 0), 0.76, PAPER)
    cylinder(0.05, 0.16, (0, 0), 0.78, ACCENT)
    return (2.4, 1.8)


def kitchen_counter():
    """Base cabinets with sink and hob; back against a south wall, front faces north."""
    box((2.6, 0.60, 0.88), (0, -0.025), 0.0, CABINET, bevel=0.01)
    box((2.6, 0.65, 0.04), (0, 0), 0.88, STONE, bevel=0.008, roughness=0.3)
    box((0.62, 0.42, 0.02), (-0.65, 0.0), 0.915, STEEL, bevel=0.03, metallic=0.7, roughness=0.25)
    box((0.50, 0.34, 0.01), (-0.65, 0.0), 0.93, (0.30, 0.32, 0.35), bevel=0.02, metallic=0.6, roughness=0.2)
    box((0.62, 0.52, 0.01), (0.70, 0.0), 0.92, (0.05, 0.05, 0.06), bevel=0.01, roughness=0.15)
    for x in (0.55, 0.85):
        for y in (-0.12, 0.12):
            cylinder(0.09, 0.006, (x, y), 0.93, (0.25, 0.25, 0.27), roughness=0.4)
    box((0.30, 0.22, 0.08), (0.05, 0.12), 0.92, WOOD_LIGHT, bevel=0.01)
    return (2.6, 0.65)


PIECES = {
    "sofa": sofa,
    "coffee_table": coffee_table,
    "tv_stand": tv_stand,
    "dining_set": dining_set,
    "kitchen_counter": kitchen_counter,
}

# --- scene and rendering -------------------------------------------------------


def reset_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    _materials.clear()
    scene = bpy.context.scene
    engines = [item.identifier for item in bpy.types.RenderSettings.bl_rna.properties["engine"].enum_items]
    scene.render.engine = "BLENDER_EEVEE" if "BLENDER_EEVEE" in engines else "BLENDER_EEVEE_NEXT"
    scene.render.film_transparent = True
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"
    scene.view_settings.view_transform = "Standard"
    world = bpy.data.worlds.new("world")
    world.use_nodes = True
    background = world.node_tree.nodes.get("Background")
    background.inputs["Color"].default_value = (0.55, 0.58, 0.62, 1.0)
    background.inputs["Strength"].default_value = 0.5
    scene.world = world
    # Light from the top-left (north-west) and above, like the in-game shading.
    sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN"))
    sun.data.energy = 2.2
    sun.data.angle = math.radians(8)
    sun.rotation_euler = (math.radians(38), 0.0, math.radians(225))
    scene.collection.objects.link(sun)
    return scene


def setup_camera(scene, width, depth):
    camera = bpy.data.objects.new("camera", bpy.data.cameras.new("camera"))
    camera.data.type = "ORTHO"
    camera.data.ortho_scale = max(width, depth)
    camera.location = (0.0, 0.0, CAMERA_Z)
    camera.data.clip_end = CAMERA_Z * 4
    scene.collection.objects.link(camera)
    scene.camera = camera
    scene.render.resolution_x = int(round(width * PIXELS_PER_METER))
    scene.render.resolution_y = int(round(depth * PIXELS_PER_METER))
    scene.render.resolution_percentage = 100
    return camera


def render_to(scene, path):
    scene.render.filepath = path
    bpy.ops.render.render(write_still=True)


def load_pixels(path):
    image = bpy.data.images.load(path)
    pixels = np.array(image.pixels[:], dtype=np.float32).reshape(image.size[1], image.size[0], 4)
    bpy.data.images.remove(image)
    return pixels


def save_pixels(pixels, path):
    height, width = pixels.shape[:2]
    image = bpy.data.images.new("strip", width=width, height=height, alpha=True)
    image.pixels = pixels.ravel().tolist()
    image.filepath_raw = path
    image.file_format = "PNG"
    image.save()
    bpy.data.images.remove(image)


def build(name):
    scene = reset_scene()
    width, depth = PIECES[name]()
    top = max(obj.location.z + obj.dimensions.z / 2.0 for obj in scene.objects if obj.type == "MESH")
    camera = setup_camera(scene, width, depth)
    out = os.path.join(OUT_DIR, name)
    os.makedirs(out, exist_ok=True)
    camera.data.clip_start = 0.05
    render_to(scene, os.path.join(out, "top.png"))
    slices = []
    tmp = os.path.join(out, "_slice.png")
    for i in range(SLICE_COUNT):
        cut = top * (i + 1) / SLICE_COUNT
        camera.data.clip_start = CAMERA_Z - cut - 0.002
        render_to(scene, tmp)
        slices.append(load_pixels(tmp))
    os.remove(tmp)
    save_pixels(np.concatenate(slices, axis=1), os.path.join(out, "slices.png"))
    print("FURNITURE %s %.2fx%.2f m top %.2f m -> %s" % (name, width, depth, top, out))


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    names = argv or list(PIECES)
    for name in names:
        build(name)


main()
