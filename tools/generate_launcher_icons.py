"""Generate DocNote's Android icons from one vector-native stationery mark.

Run with Python + Pillow. No Flutter/runtime dependency is introduced.
"""
from pathlib import Path
from xml.sax.saxutils import escape

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
RES = ROOT / "android/app/src/main/res"
BACKGROUND = "#EDF3FA"
# All essential detail stays inside the adaptive icon's central safe region.
SHAPES = [
    ("round", (31, 26, 77, 82, 7), "#2F6EAA"),
    ("round", (38, 29, 74, 78, 4), "#FFFFFF"),
    ("rect", (38, 29, 42, 78), "#E1EBF5"),
    ("polygon", ((63, 29), (70, 29), (70, 48), (66.5, 45), (63, 48)), "#D88570"),
    ("round", (47, 54, 65, 56, 1), "#8BA6BE"),
    ("round", (47, 62, 60, 64, 1), "#8BA6BE"),
]


def path_data(kind, coords):
    if kind == "polygon":
        return "M" + "L".join(f"{x},{y}" for x, y in coords) + "Z"
    x, y, right, bottom, *radius = coords
    if not radius:
        return f"M{x},{y}H{right}V{bottom}H{x}Z"
    r = radius[0]
    return (f"M{x+r},{y}H{right-r}Q{right},{y} {right},{y+r}"
            f"V{bottom-r}Q{right},{bottom} {right-r},{bottom}"
            f"H{x+r}Q{x},{bottom} {x},{bottom-r}"
            f"V{y+r}Q{x},{y} {x+r},{y}Z")


def vector(shapes):
    paths = "\n".join(
        f'    <path android:fillColor="{color}" android:pathData="{escape(path_data(kind, coords))}" />'
        for kind, coords, color in shapes
    )
    return ('<?xml version="1.0" encoding="utf-8"?>\n'
            '<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
            '    android:width="108dp" android:height="108dp"\n'
            '    android:viewportWidth="108" android:viewportHeight="108">\n'
            + paths + '\n</vector>\n')


def render(size):
    scale = size * 4 / 108
    image = Image.new("RGB", (size * 4, size * 4), BACKGROUND)
    draw = ImageDraw.Draw(image)
    for kind, coords, color in SHAPES:
        if kind == "polygon":
            draw.polygon([(x*scale, y*scale) for x, y in coords], fill=color)
        else:
            bounds = tuple(v*scale for v in coords[:4])
            if kind == "round":
                draw.rounded_rectangle(bounds, coords[4]*scale, fill=color)
            else:
                draw.rectangle(bounds, fill=color)
    # Adaptive icons display the central 72dp of a 108dp layer. Flattened
    # launcher/store PNGs need that same visible framing, not motion padding.
    image = image.crop(tuple(round(v * scale) for v in (18, 18, 90, 90)))
    return image.resize((size, size), Image.Resampling.LANCZOS)


def main():
    brand = ROOT / "assets/brand"
    brand.mkdir(parents=True, exist_ok=True)
    paths = "\n".join(
        f'  <path fill="{color}" d="{path_data(kind, coords)}" />'
        for kind, coords, color in SHAPES
    )
    (brand / "docnote_mark.svg").write_text(
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="28 24 52 60">\n'
        + paths + '\n</svg>\n', encoding="utf-8")
    (RES / "drawable/ic_launcher_foreground.xml").write_text(vector(SHAPES), encoding="utf-8")
    (RES / "drawable/ic_launcher.xml").write_text(
        vector([("rect", (0, 0, 108, 108), BACKGROUND), *SHAPES]), encoding="utf-8")
    (RES / "values/ic_launcher_colors.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n'
        f'    <color name="ic_launcher_background">{BACKGROUND}</color>\n</resources>\n', encoding="utf-8")
    for density, size in {"mdpi":48, "hdpi":72, "xhdpi":96, "xxhdpi":144, "xxxhdpi":192}.items():
        render(size).save(RES / f"mipmap-{density}/ic_launcher.png")
    output = ROOT / "store_assets/google_play/icon.png"
    render(512).save(output)


if __name__ == "__main__":
    main()
