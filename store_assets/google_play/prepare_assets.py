"""Prepare unframed Google Play screenshots and the DocNote feature graphic.

Run from the repository root after capturing the raw emulator screens in build/qa.
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


ROOT = Path(__file__).resolve().parents[2]
ASSETS = ROOT / "store_assets" / "google_play"
QA = ROOT / "build" / "qa"


def screenshot(source: str, target: str, size: tuple[int, int]) -> None:
    image = Image.open(QA / source).convert("RGB")
    if image.size != size:
        raise ValueError(f"{source}: expected {size}, got {image.size}")
    # The emulator's first capture sometimes includes a 1 px focus outline.
    # Remove only the outside pixel and restore the exact native dimensions.
    if source.endswith("-raw.png"):
        edge = image.getpixel((0, image.height // 2))
        if edge[1] > 140 and edge[0] < 170 and edge[2] < 120:
            image = image.crop((2, 2, image.width - 2, image.height - 2))
            image = image.resize(size, Image.Resampling.LANCZOS)
    destination = ASSETS / "screenshots" / target
    destination.parent.mkdir(parents=True, exist_ok=True)
    image.save(destination, "JPEG", quality=95, subsampling=0, optimize=True)


def feature_graphic() -> None:
    size = (1024, 500)
    image = Image.new("RGB", size, "#F7F8FB")
    draw = ImageDraw.Draw(image)
    bold = "C:/Windows/Fonts/malgunbd.ttf"
    regular = "C:/Windows/Fonts/malgun.ttf"
    draw.rounded_rectangle((44, 45, 980, 455), radius=38, fill="#FFFFFF")
    draw.rounded_rectangle((82, 103, 161, 183), radius=16, fill="#DCEAFF")
    draw.rounded_rectangle((102, 119, 143, 169), radius=4, fill="#FFFFFF", outline="#3470BA", width=3)
    draw.line((111, 134, 134, 134), fill="#82A9D4", width=2)
    draw.line((111, 144, 130, 144), fill="#82A9D4", width=2)
    draw.line((111, 154, 126, 154), fill="#82A9D4", width=2)
    draw.text((84, 208), "DocNote", font=ImageFont.truetype(bold, 72), fill="#1F2937")
    draw.text((88, 314), "노트와 문서를 한곳에", font=ImageFont.truetype(regular, 29), fill="#6B7280")
    # Notebook and document objects reflect the app's library presentation.
    draw.rounded_rectangle((602, 116, 772, 369), radius=12, fill="#DFEAF5")
    draw.rectangle((622, 134, 629, 350), fill="#42719B")
    draw.line((650, 172, 737, 172), fill="#91AEC9", width=3)
    draw.line((650, 183, 716, 183), fill="#91AEC9", width=3)
    draw.text((647, 305), "NOTES", font=ImageFont.truetype(bold, 24), fill="#315F88")
    draw.rounded_rectangle((790, 145, 934, 369), radius=8, fill="#FFFFFF", outline="#E7EBF1", width=2)
    draw.line((812, 205, 914, 205), fill="#7FA3CD", width=4)
    draw.line((812, 230, 906, 230), fill="#B8C9DD", width=3)
    draw.line((812, 251, 906, 251), fill="#B8C9DD", width=3)
    draw.line((812, 272, 884, 272), fill="#B8C9DD", width=3)
    draw.rounded_rectangle((811, 320, 868, 345), radius=5, fill="#E5EFFA")
    draw.text((820, 323), "PDF", font=ImageFont.truetype(bold, 14), fill="#376895")
    image.save(ASSETS / "feature-graphic.png", optimize=True)


if __name__ == "__main__":
    for source, target in [
        ("home2-raw.png", "phone/01-home-library.jpg"),
        ("editor-final-raw.png", "phone/02-notebook-editor.jpg"),
        ("hwp-final-raw.png", "phone/03-hwp-document.jpg"),
        ("sheet-final.png", "phone/04-create-sheet.jpg"),
        ("search-final-raw.png", "phone/05-search-results.jpg"),
    ]:
        screenshot(source, target, (1080, 2160))
    for source, target in [
        ("tabhome-final-raw.png", "tablet/01-tablet-home.jpg"),
        ("tabdocs-final-raw.png", "tablet/02-tablet-documents.jpg"),
        ("tabeditor-full-raw.png", "tablet/03-tablet-notebook-editor.jpg"),
        ("tabcreate-final-raw.png", "tablet/04-tablet-create-sheet.jpg"),
        ("tabsearch-final-raw.png", "tablet/05-tablet-search.jpg"),
    ]:
        screenshot(source, target, (1920, 1080))
    feature_graphic()
