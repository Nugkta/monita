"""Build docs/assets/demo.gif from the app's own synthetic previews.

Run after `sh task-island/release.sh` has built the app. Every panel image comes
from `Monita --render-preview`, which uses built-in sample tasks only; no real
task, title or screen is captured. The menu bar, notch, pointer and captions are
drawn here. Requires Pillow (`python3 -m pip install Pillow`).

    python3 docs/make-demo.py
"""
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / 'task-island/Monita.app/Contents/MacOS/Monita'
OUT = ROOT / 'docs/assets/demo.gif'
S = 2                       # previews are rendered at 2x
W, H = 600, 380             # canvas in points
MENU = 32                   # menu bar height, as on a notched MacBook
NOTCH = 210                 # camera housing width used by the previews
CX = W // 2                 # notch centre


def font(size):
    for path in ('/System/Library/Fonts/SFNS.ttf', '/System/Library/Fonts/Helvetica.ttc'):
        try:
            return ImageFont.truetype(path, size * S)
        except OSError:
            continue
    return ImageFont.load_default()


CAPTION = font(13)
MENU_TEXT = font(12)


def render(directory, name, *flags):
    path = Path(directory) / f'{name}.png'
    subprocess.run([str(APP), '--render-preview', str(path), *flags], check=True)
    return Image.open(path).convert('RGBA')


def backdrop():
    """A plain desktop with a light menu bar and the camera housing."""
    # Flat colours, so the GIF palette keeps room for the provider and state accents.
    image = Image.new('RGBA', (W * S, H * S), (104, 116, 150, 255))
    draw = ImageDraw.Draw(image)
    draw.rectangle([0, 0, W * S, MENU * S], fill=(228, 228, 232, 235))
    for x, label in ((14, 'Finder'), (70, 'File'), (106, 'Edit'), (144, 'View')):
        draw.text((x * S, 8 * S), label, font=MENU_TEXT, fill=(40, 40, 44, 255))
    draw.rounded_rectangle([(CX - NOTCH // 2) * S, -12 * S, (CX + NOTCH // 2) * S, MENU * S], radius=9 * S, fill=(0, 0, 0, 255))
    return image


def place(canvas, panel, left, top, shadow=True):
    """Paste a rendered panel at a point position, with a soft shadow."""
    if shadow:
        pad = 24 * S
        alpha = Image.new('L', (panel.width + 2 * pad, panel.height + 2 * pad), 0)
        alpha.paste(panel.getchannel('A'), (pad, pad))
        alpha = alpha.filter(ImageFilter.GaussianBlur(10 * S)).point(lambda a: int(a * 0.45))
        shade = Image.new('RGBA', alpha.size, (0, 0, 0, 255))
        shade.putalpha(alpha)
        canvas.alpha_composite(shade, (int(left * S) - pad, int((top + 6) * S) - pad))
    canvas.alpha_composite(panel, (int(left * S), int(top * S)))


def pointer(canvas, x, y):
    """A plain arrow pointer with its tip at (x, y)."""
    shape = [(0, 0), (0, 17), (4.5, 13), (7.5, 19.5), (10, 18.5), (7, 12), (12.5, 12)]
    points = [((x + px) * S, (y + py) * S) for px, py in shape]
    draw = ImageDraw.Draw(canvas)
    draw.polygon(points, fill=(0, 0, 0, 255), outline=(255, 255, 255, 255), width=int(1.4 * S))


def caption(canvas, text):
    draw = ImageDraw.Draw(canvas)
    box = draw.textbbox((0, 0), text, font=CAPTION)
    width, height = box[2] - box[0], box[3] - box[1]
    x, y = (W * S - width) // 2, (H - 30) * S
    draw.rounded_rectangle([x - 12 * S, y - 7 * S, x + width + 12 * S, y + height + 9 * S], radius=8 * S, fill=(0, 0, 0, 150))
    draw.text((x, y - box[1]), text, font=CAPTION, fill=(255, 255, 255, 255))


def main():
    if not APP.exists():
        sys.exit('Build the app first: sh task-island/release.sh')
    with tempfile.TemporaryDirectory() as directory:
        compact = render(directory, 'compact', '--collapsed', '--floating')
        review = render(directory, 'review', '--floating')
        running = render(directory, 'running', '--floating', '--preview-running')
        needs_input = render(directory, 'input', '--floating', '--preview-input')
        island = render(directory, 'island', '--collapsed')
        island_running = render(directory, 'island-running', '--preview-running')
        island_review = render(directory, 'island-review')

    frames, durations = [], []

    def frame(ms, panel=None, at=None, cursor=None, text=None, shadow=True):
        canvas = backdrop()
        if panel is not None:
            place(canvas, panel, *at, shadow=shadow)
        if cursor:
            pointer(canvas, *cursor)
        if text:
            caption(canvas, text)
        frames.append(canvas)
        durations.append(ms)

    float_top = MENU + 12
    compact_at = (CX - compact.width // (2 * S), float_top)
    open_at = (CX - 220, float_top)
    # The open bar's three tabs, in canvas points: (440 - 16 - 24 - 12) / 3 each.
    tab = (440 - 16 - 24 - 12) / 3
    tab_x = [open_at[0] + 8 + tab / 2 + i * (tab + 4) for i in range(3)]
    bar_y = float_top + 14

    hover = 'Hover to open; rest on a count to switch'
    frame(900, compact, compact_at, (430, 170), 'Running · Input · Review, always in view')
    frame(500, compact, compact_at, (356, bar_y), hover)
    frame(1500, review, open_at, (tab_x[2] - 4, bar_y), hover)
    frame(1300, running, open_at, (tab_x[0], bar_y), hover)
    frame(1300, needs_input, open_at, (tab_x[1], bar_y), hover)

    # Dragged up into the menu bar over the housing, it docks.
    dock = 'Drag it into the menu bar to dock beside the notch'
    left = compact_at[0]
    frame(700, compact, compact_at, (CX + 8, float_top + 16), dock)
    for top in (34, 24, 14, 6):
        frame(90, compact, (left, top), (CX + 8, top + 16), dock)
    island_left = CX - NOTCH // 2 - 52            # 52pt left ear
    frame(1300, island, (island_left, 0), (CX + 8, 18), 'Docked: Running left, Input and Review right', shadow=False)

    # The ears are the tabs; open, the list hangs centred under the housing.
    ears = 'The ears are the tabs'
    frame(1500, island_running, (CX - 220, 0), (CX - NOTCH // 2 - 52 + 26, 16), ears, shadow=False)
    frame(1500, island_review, (CX - 220, 0), (CX + NOTCH // 2 + 82, 16), ears, shadow=False)

    # One shared palette keeps colours steady between frames and the file small.
    scaled = [f.convert('RGB').resize((W * 3 // 2, H * 3 // 2), Image.LANCZOS) for f in frames]
    sheet = Image.new('RGB', (scaled[0].width, scaled[0].height * len(scaled)))
    for index, image in enumerate(scaled):
        sheet.paste(image, (0, index * image.height))
    palette = sheet.quantize(colors=255, method=Image.Quantize.FASTOCTREE)
    gif = [f.quantize(palette=palette, dither=Image.Dither.NONE) for f in scaled]
    OUT.parent.mkdir(parents=True, exist_ok=True)
    gif[0].save(OUT, save_all=True, append_images=gif[1:], duration=durations, loop=0, optimize=True, disposal=1)
    print(f'Wrote {OUT.relative_to(ROOT)} ({OUT.stat().st_size // 1024} KB, {len(gif)} frames)')


if __name__ == '__main__':
    main()
