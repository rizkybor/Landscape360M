"""App icons and splash screens from the logo (tool/brand/logo_1080.png, the web's
src/assets/LandscapeLogo.png). Run from the project root after changing the logo:

    python3 tool/brand/make_icons.py

Writes the iOS AppIcon and LaunchImage sets, the Android launcher icons (adaptive and
legacy) and splash images, and the store icons in store/ (1024 App Store, 512 Google Play).
"""

import json
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
LOGO = Image.open(Path(__file__).with_name("logo_1080.png")).convert("RGBA")
BACKGROUND = (0xFA, 0xF8, 0xF3)  # L360Colors.sand50, the app's surface colour

# The logo without its empty border
LOGO = LOGO.crop(LOGO.getbbox())


def logo_on(size, share, background=BACKGROUND, lift=0.0):
    """A square of `size` with the logo filling `share` of it, centred (raised by `lift` of
    the size: the pin makes the logo look low when centred exactly)"""
    canvas = Image.new("RGBA", (size, size), background + (255,) if background else (0, 0, 0, 0))
    scale = share * size / max(LOGO.size)
    logo = LOGO.resize((round(LOGO.width * scale), round(LOGO.height * scale)), Image.LANCZOS)
    x = (size - logo.width) // 2
    y = (size - logo.height) // 2 - round(lift * size)
    canvas.alpha_composite(logo, (x, y))
    return canvas


def save_rgb(image, path):
    """No transparency (App Store rejects icons with an alpha channel)"""
    path.parent.mkdir(parents=True, exist_ok=True)
    image.convert("RGB").save(path, optimize=True)


def save_rgba(image, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, optimize=True)


def rounded(image, radius_share):
    mask = Image.new("L", image.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, image.width - 1, image.height - 1), radius=round(radius_share * image.width), fill=255
    )
    out = Image.new("RGBA", image.size, (0, 0, 0, 0))
    out.paste(image, (0, 0), mask)
    return out


# --- iOS ---------------------------------------------------------------------------------------

ICON_SHARE = 0.80  # iOS masks the corners itself; the logo keeps clear of them
master = logo_on(1024, ICON_SHARE, lift=0.01)
app_icon = ROOT / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
for entry in json.loads((app_icon / "Contents.json").read_text())["images"]:
    points = float(entry["size"].split("x")[0])
    px = round(points * int(entry["scale"][0]))
    save_rgb(master.resize((px, px), Image.LANCZOS), app_icon / entry["filename"])

launch = ROOT / "ios/Runner/Assets.xcassets/LaunchImage.imageset"
SPLASH_POINTS = 168  # matches LaunchScreen.storyboard
for scale, name in [(1, "LaunchImage.png"), (2, "LaunchImage@2x.png"), (3, "LaunchImage@3x.png")]:
    save_rgba(logo_on(SPLASH_POINTS * scale, 1.0, background=None), launch / name)

# --- Android -----------------------------------------------------------------------------------

res = ROOT / "android/app/src/main/res"
DENSITIES = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}
for name, d in DENSITIES.items():
    # Legacy launcher (before Android 8): a rounded square
    legacy = rounded(logo_on(512, 0.78, lift=0.01), 0.18)
    save_rgba(legacy.resize((round(48 * d), round(48 * d)), Image.LANCZOS), res / f"mipmap-{name}/ic_launcher.png")
    # Adaptive foreground: 108 dp with the logo inside the 66 dp safe zone
    fg = logo_on(432, 0.58, background=None, lift=0.01)
    save_rgba(fg.resize((round(108 * d), round(108 * d)), Image.LANCZOS), res / f"drawable-{name}/ic_launcher_foreground.png")
    # Splash (before Android 12): the logo, 160 dp, on the background colour
    save_rgba(logo_on(round(160 * d), 1.0, background=None), res / f"drawable-{name}/launch_image.png")

# --- Store -------------------------------------------------------------------------------------

save_rgb(master, ROOT / "store/icon-app-store-1024.png")
save_rgb(master.resize((512, 512), Image.LANCZOS), ROOT / "store/icon-google-play-512.png")
print("icons and splash written")
