"""Store screenshots with a caption, and the Google Play feature graphic.

    python3 tool/store/frame_screenshots.py

Reads the raw screenshots in store/screenshots/<device>/ (tool/store/screenshots.sh) and
writes store/framed/<lang>/<device>/<name>.png: the screen's size for Apple, 1080 x 1920 for
Android (Play wants the long side at most twice the short one). Captions are below, in Indonesian and English.
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[2]
FONT = ROOT / "assets/fonts/Inter-Variable.ttf"
LOGO = Image.open(ROOT / "tool/brand/logo_1080.png").convert("RGBA")
LOGO = LOGO.crop(LOGO.getbbox())

FOREST_800 = (0x1E, 0x3C, 0x13)
FOREST_900 = (0x12, 0x2B, 0x0A)
GOLD_400 = (0xE9, 0xB6, 0x40)
SAND_100 = (0xF3, 0xF0, 0xE7)
EMBER_500 = (0xE4, 0x6C, 0x24)

CAPTIONS = {
    "1_3d_terrain": {
        "id": ("Lihat medan dalam 3D", "Kontur, ketinggian dan citra satelit"),
        "en": ("See the terrain in 3D", "Contours, elevation and satellite imagery"),
    },
    "2_navigator": {
        "id": ("Rencanakan jalur pendakian", "Garis lengkung atau siku, jarak dan azimuth"),
        "en": ("Plan your route", "Curves or sharp corners, distance and bearing"),
    },
    "3_track_recorder": {
        "id": ("Rekam setiap perjalanan", "Tetap merekam saat layar mati"),
        "en": ("Record every climb", "Keeps recording with the screen off"),
    },
    "4_area_focus": {
        "id": ("Tandai area penting", "Mode fokus untuk zona camp dan bahaya"),
        "en": ("Mark the areas that matter", "Focus mode for camps and danger zones"),
    },
    "5_offline_map": {
        "id": ("Peta offline tanpa sinyal", "Unduh area sebelum berangkat"),
        "en": ("Maps without signal", "Download the area before you go"),
    },
    "6_my_location": {
        "id": ("Tahu posisimu di gunung", "Koordinat, ketinggian dan arah kompas"),
        "en": ("Know where you stand", "Coordinates, elevation and compass heading"),
    },
    "7_sos": {
        "id": ("S.O.S saat darurat", "Lokasimu ke admin, 112 dan Basarnas"),
        "en": ("S.O.S when it counts", "Your location to the admin, 112 and Basarnas"),
    },
}


def font(size, weight):
    f = ImageFont.truetype(str(FONT), size)
    # Inter's axes by name: weight, and the optical size matched to the text size
    values = []
    for axis in f.get_variation_axes():
        name = axis["name"].decode() if isinstance(axis["name"], bytes) else str(axis["name"])
        if name.lower().startswith("weight"):
            values.append(weight)
        else:
            values.append(max(axis["minimum"], min(axis["maximum"], size)))
    f.set_variation_by_axes(values)
    return f


def gradient(size):
    w, h = size
    top, bottom = FOREST_800, FOREST_900
    column = Image.new("RGB", (1, h))
    for y in range(h):
        t = y / max(1, h - 1)
        column.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))
    return column.resize((w, h))


def rounded(image, radius):
    mask = Image.new("L", image.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, image.width - 1, image.height - 1), radius=radius, fill=255)
    out = Image.new("RGBA", image.size, (0, 0, 0, 0))
    out.paste(image, (0, 0), mask)
    return out


def centered(draw, text, y, f, fill, width):
    w = draw.textlength(text, font=f)
    draw.text(((width - w) / 2, y), text, font=f, fill=fill)


def frame(shot_path, title, subtitle, out_path, size=None):
    """[size]: the canvas, when the store wants another shape than the screen (Play: the
    long side at most twice the short one, so 1080 x 1920 for today's tall phones)"""
    shot = Image.open(shot_path).convert("RGBA")
    w, h = size or shot.size
    canvas = gradient((w, h)).convert("RGBA")
    draw = ImageDraw.Draw(canvas)

    # Caption: a short title and one line under it
    unit = min(w, h * 0.6)
    title_font = font(round(unit * 0.072), 800)
    sub_font = font(round(unit * 0.036), 500)
    top = round(h * 0.055)
    centered(draw, title, top, title_font, SAND_100, w)
    centered(draw, subtitle, top + round(unit * 0.105), sub_font, GOLD_400, w)

    # The screen, scaled into the space left, rounded, with a soft shadow
    caption_bottom = top + round(unit * 0.17)
    room_h = h - caption_bottom - round(h * 0.035)
    scale = min(room_h / shot.height, (w * 0.86) / shot.width)
    sw, sh = round(shot.width * scale), round(shot.height * scale)
    screen = rounded(shot.resize((sw, sh), Image.LANCZOS), round(sw * 0.07))
    x, y = (w - sw) // 2, caption_bottom + round(h * 0.01)
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (x, y + round(sh * 0.01), x + sw, y + sh + round(sh * 0.01)), radius=round(sw * 0.07), fill=(0, 0, 0, 110)
    )
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(round(w * 0.02))))
    canvas.alpha_composite(screen, (x, y))

    out_path.parent.mkdir(parents=True, exist_ok=True)
    canvas.convert("RGB").save(out_path, optimize=True)


def feature_graphic(out_path):
    """Google Play feature graphic, 1024 x 500"""
    w, h = 1024, 500
    canvas = gradient((w, h)).convert("RGBA")
    logo_h = 300
    logo = LOGO.resize((round(LOGO.width * logo_h / LOGO.height), logo_h), Image.LANCZOS)
    canvas.alpha_composite(logo, (70, (h - logo_h) // 2))
    draw = ImageDraw.Draw(canvas)
    x = 70 + logo.width + 50
    name = font(64, 800)
    draw.text((x, 150), "Landscape 360", font=name, fill=SAND_100)
    app_x = x + draw.textlength("Landscape 360 ", font=name)
    draw.text((app_x, 156), "app", font=font(30, 800), fill=EMBER_500)
    draw.text((x, 240), "Explore without Limits", font=font(34, 600), fill=GOLD_400)
    draw.text((x, 298), "Navigasi, jalur, rekam perjalanan,", font=font(24, 500), fill=SAND_100)
    draw.text((x, 332), "peta offline dan S.O.S", font=font(24, 500), fill=SAND_100)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    canvas.convert("RGB").save(out_path, optimize=True)


for device_dir in sorted((ROOT / "store/screenshots").iterdir()):
    if not device_dir.is_dir():
        continue
    for shot in sorted(device_dir.glob("*.png")):
        captions = CAPTIONS.get(shot.stem)
        if captions is None:
            continue
        for lang, (title, subtitle) in captions.items():
            size = (1080, 1920) if device_dir.name.startswith("android") else None
            frame(shot, title, subtitle, ROOT / f"store/framed/{lang}/{device_dir.name}/{shot.name}", size)
feature_graphic(ROOT / "store/google-play-feature-graphic.png")
print("framed screenshots and feature graphic written")
