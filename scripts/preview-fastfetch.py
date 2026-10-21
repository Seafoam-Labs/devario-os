#!/usr/bin/env python3
"""Preview the Devario Fastfetch layout without installing system configuration."""

import argparse
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "iso/late-airootfs/usr/share/devario/fastfetch"
OPTIONS = {"image": "Devario logo (default)", "striped": "Striped Devario",
           "compact": "Compact outline", "bold": "Bold silhouette"}


def configuration(option, sample=False):
    config = json.loads((ASSETS / "config.jsonc").read_text())
    config["logo"]["source"] = str(ASSETS / "devario-logo.png")
    if option != "image":
        config["logo"].update(type="file", source=str(ASSETS / f"fish-{option}.txt"))
        config["logo"].pop("width", None)
        config["logo"].pop("height", None)
    if sample:
        # Illustrative values only; the installed configuration detects real data.
        values = {
            "OS": ["Devario OS x86_64"], "Kernel": ["Linux 7.2.9-2-cachyos"],
            "WM": ["Pearl-Git:Aqueous-Git"], "Compositor": ["aqueous (Wayland)"],
            "Packages": ["1856 (Shelly)"], "Ram": ["28.47 GiB / 60.46 GiB (47%)"],
            "CPU": ["AMD Ryzen 9 9950X3D (32) @ 5.76 GHz"],
            "GPU": ["AMD Radeon 610M [Integrated]", "NVIDIA GeForce RTX 5090 [Discrete]"],
            "Swap": ["1.07 GiB / 60.46 GiB (2%)"],
            "Disk": ["996.41 GiB / 1.82 TiB (54%) - btrfs", "1.13 TiB / 1.79 TiB (63%) - ext4"],
            "Zig": ["0.16.0"], "dotnet": ["10.0.112"],
            "Uptime": ["7 hours, 6 mins"], "Terminal": ["ghostty 1.3.1-arch2.1"],
        }
        modules = []
        for module in config["modules"]:
            key = module.get("key", "").removeprefix("◎ ")
            if key in values:
                modules.extend({"type": "custom", "key": module["key"], "format": value}
                               for value in values[key])
            else:
                modules.append(module)
        config["modules"] = modules
    return config


def render(config, destination, sample):
    """Rasterize real Fastfetch ANSI output and its image into a terminal example."""
    from PIL import Image, ImageDraw, ImageFont

    font_dir = Path("/usr/share/fonts/noto")
    fonts = [ImageFont.truetype(str(font_dir / name), 18) for name in
             ("NotoSansMono-Regular.ttf", "NotoSansMono-Bold.ttf")]
    cell, line_height, margin = fonts[0].getlength("M"), 24, 32
    logo = config["logo"]
    text_config = dict(config, logo={"type": "none"}) if logo["type"] == "auto" else config
    output = subprocess.check_output(["fastfetch", "--config", "-", "--pipe", "false"],
                                     input=json.dumps(text_config), text=True)
    ansi = re.compile(r"\x1b\[([0-9;]*)m")
    lines = output.rstrip().splitlines()
    stacked = logo.get("position") == "top"
    logo_columns = logo["width"] + logo["padding"]["right"] if logo["type"] == "auto" and not stacked else 0
    columns = max(len(ansi.sub("", line)) for line in lines)
    picture, logo_top, text_top = None, 0, 0
    if logo["type"] == "auto":
        picture = Image.open(logo["source"]).convert("RGBA")
        logo_width = round(logo["width"] * cell)
        picture.thumbnail((logo_width, round(logo_width * picture.height / picture.width)),
                          Image.Resampling.LANCZOS)
        logo_top = logo["padding"].get("top", 0) * line_height
        if stacked:
            logo_rows = (picture.height + line_height - 1) // line_height
            text_top = logo_top + (logo_rows + logo["padding"].get("bottom", 0)) * line_height
    content_width = round((logo_columns + columns) * cell)
    content_height = text_top + line_height * len(lines)
    if picture is not None:
        content_width = max(content_width, picture.width)
        content_height = max(content_height, logo_top + picture.height)
    width = content_width + margin * 2
    height = content_height + margin * 2 + 32
    canvas = Image.new("RGB", (width, height), "#201a25")
    draw = ImageDraw.Draw(canvas)
    palette = ["#201a25", "#b98088", "#93b58b", "#c2b484", "#78a9ba", "#a692b5",
               "#62c6b5", "#c9c6cf", "#716977", "#ce9aa2", "#aecaa8", "#d8c999",
               "#97c3d3", "#c2b0d1", "#84dfcf", "#eeeaf2"]
    if picture is not None:
        canvas.paste(picture, (margin, margin + logo_top), picture)
    for row, line in enumerate(lines):
        x, color, bold, pos = margin + logo_columns * cell, palette[7], False, 0
        for match in ansi.finditer(line):
            fragment = line[pos:match.start()]
            draw.text((x, margin + text_top + row * line_height), fragment, font=fonts[bold], fill=color)
            x += len(fragment) * cell
            codes = [int(v) if v else 0 for v in match.group(1).split(";")]
            index = 0
            while index < len(codes):
                code = codes[index]
                if code == 0:
                    color, bold = palette[7], False
                elif code == 1:
                    bold = True
                elif code == 22:
                    bold = False
                elif code == 39:
                    color = palette[7]
                elif 30 <= code <= 37:
                    color = palette[code - 30]
                elif 90 <= code <= 97:
                    color = palette[code - 90 + 8]
                elif code == 38 and codes[index + 1] == 2:
                    color = tuple(codes[index + 2:index + 5])
                    index += 4
                elif code == 38 and codes[index + 1] == 5:
                    color = palette[codes[index + 2]]
                    index += 2
                index += 1
            pos = match.end()
        draw.text((x, margin + text_top + row * line_height), line[pos:], font=fonts[bold], fill=color)
    caption = "Illustrative system values" if sample else "Detected system values"
    draw.text((margin, height - 30), caption, font=fonts[0], fill=palette[8])
    canvas.save(destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("option", choices=[*OPTIONS, "all"], nargs="?", default="image")
    parser.add_argument("--sample", action="store_true", help="use labeled illustrative system values")
    parser.add_argument("--render", type=Path, help="save a PNG example (requires Pillow and Noto Sans Mono)")
    args = parser.parse_args()
    if args.render:
        if args.option == "all":
            parser.error("--render requires a single logo option")
        render(configuration(args.option, args.sample), args.render, args.sample)
        return
    for option in OPTIONS if args.option == "all" else [args.option]:
        suffix = " (illustrative values)" if args.sample else " (this machine's values)"
        print(f"\n{OPTIONS[option]}{suffix}\n", flush=True)
        subprocess.run(
            ["fastfetch", "--config", "-", "--pipe", "false"],
            input=json.dumps(configuration(option, args.sample)), text=True, check=True,
        )


if __name__ == "__main__":
    main()
