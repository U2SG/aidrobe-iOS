#!/usr/bin/env python3
"""Seed the local dev user with a believable wardrobe (drawn garments, no photos).

Draws each garment as an SVG "floor shot", rasterises it with macOS QuickLook,
then runs the real pipeline: presign -> upload -> import task -> confirm.
Needs the local stack from aidrobe-BE `scripts/dev-up.sh`. Costs nothing.

    scripts/dev-seed-wardrobe.py            # add the wardrobe
    scripts/dev-seed-wardrobe.py --reset    # delete the dev user's items first
"""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

API = "http://localhost:8000"
USER = "00000000-0000-4000-8000-000000000001"
INTERNAL_HOSTS = {"minio", "localhost", "127.0.0.1", "0.0.0.0"}

TEE = "M300 170 Q400 215 500 170 L640 235 L700 400 L590 440 L570 360 L570 850 L230 850 L230 360 L210 440 L100 400 L160 235 Z"
LONG = "M300 160 Q400 205 500 160 L630 215 L720 760 L625 785 L575 420 L570 850 L230 850 L225 420 L175 785 L80 760 L170 215 Z"
COAT = "M310 110 L400 190 L490 110 L625 170 L715 800 L620 825 L585 430 L600 930 L200 930 L215 430 L180 825 L85 800 L175 170 Z"
JACKET = "M310 150 L400 230 L490 150 L625 205 L710 730 L615 755 L580 430 L585 790 L215 790 L220 430 L185 755 L90 730 L175 205 Z"
TROUSERS = "M255 90 L545 90 L585 930 L425 930 L400 330 L375 930 L215 930 Z"
WIDE = "M250 90 L550 90 L640 930 L420 930 L400 330 L380 930 L160 930 Z"
DRESS = "M320 110 Q400 170 480 110 L530 150 L515 400 L640 900 L160 900 L285 400 L270 150 Z"
SHOE = "M40 150 Q40 60 120 55 L180 60 Q230 120 330 135 Q400 145 400 190 L400 205 L40 205 Z"

# (title, category, color_main, fill, shape, detail)
WARDROBE = [
    ("白色圆领 T 恤", "top", "white", "#F4F1EA", TEE, ""),
    ("藏青条纹衫", "top", "navy", "#27324A", LONG, "stripes"),
    ("燕麦色针织衫", "top", "beige", "#D9C8A9", LONG, "rib"),
    ("浅蓝牛津衬衫", "top", "blue", "#A9C1DC", LONG, "placket"),
    ("黑色高领打底", "top", "black", "#24211E", LONG, "rib"),
    ("原色直筒牛仔裤", "bottom", "blue", "#34496B", TROUSERS, "seam"),
    ("卡其直筒裤", "bottom", "khaki", "#B9A27A", TROUSERS, "seam"),
    ("黑色西裤", "bottom", "black", "#2A2725", TROUSERS, "crease"),
    ("灰色阔腿裤", "bottom", "gray", "#8E8C88", WIDE, "crease"),
    ("驼色羊毛大衣", "outerwear", "camel", "#B98A55", COAT, "lapel"),
    ("藏青西装外套", "outerwear", "navy", "#232D44", JACKET, "lapel"),
    ("橄榄绿工装夹克", "outerwear", "green", "#5F6644", JACKET, "placket"),
    ("黑色连衣裙", "dress", "black", "#262321", DRESS, ""),
    ("白色运动鞋", "shoes", "white", "#EFECE5", SHOE, "sole"),
    ("棕色乐福鞋", "shoes", "brown", "#6B4630", SHOE, "sole"),
    ("黑色短靴", "shoes", "black", "#2B2826", SHOE, "sole"),
]


# title -> (material, season_tags, formality_score 0..100), as recognition would fill them.
ATTRIBUTES = {
    "白色圆领 T 恤": ("cotton", ["spring", "summer", "autumn"], 30),
    "藏青条纹衫": ("cotton", ["spring", "autumn"], 30),
    "燕麦色针织衫": ("wool", ["autumn", "winter"], 50),
    "浅蓝牛津衬衫": ("cotton", ["all_season"], 70),
    "黑色高领打底": ("wool", ["autumn", "winter"], 50),
    "原色直筒牛仔裤": ("denim", ["all_season"], 30),
    "卡其直筒裤": ("cotton", ["spring", "autumn"], 50),
    "黑色西裤": ("wool", ["all_season"], 90),
    "灰色阔腿裤": ("polyester", ["all_season"], 70),
    "驼色羊毛大衣": ("wool", ["winter"], 70),
    "藏青西装外套": ("wool", ["spring", "autumn"], 90),
    "橄榄绿工装夹克": ("cotton", ["spring", "autumn"], 30),
    "黑色连衣裙": ("polyester", ["spring", "summer"], 70),
    "白色运动鞋": ("leather", ["all_season"], 10),
    "棕色乐福鞋": ("leather", ["all_season"], 70),
    "黑色短靴": ("leather", ["autumn", "winter"], 50),
}


def set_attributes(item_id: str, title: str) -> None:
    material, seasons, formality = ATTRIBUTES[title]
    call(
        "PATCH",
        f"/v1/wardrobe-items/{item_id}",
        {"material": material, "season_tags": seasons, "formality_score": formality},
    )


def details(kind: str, fill: str) -> str:
    dark = "#000" if fill > "#7" else "#fff"
    line = f'stroke="{dark}" stroke-opacity="0.22" stroke-width="3" fill="none"'
    if kind == "stripes":
        return "".join(
            f'<rect x="0" y="{y}" width="800" height="14" fill="#F1ECE1" opacity="0.9"/>' for y in range(250, 850, 46)
        )
    if kind == "rib":
        return f'<path d="M230 815 H570 M300 160 Q400 235 500 160" {line}/>'
    if kind == "placket":
        buttons = "".join(f'<circle cx="400" cy="{y}" r="6" fill="{dark}" opacity="0.3"/>' for y in range(290, 800, 95))
        return f'<path d="M400 210 V850 M310 165 L400 250 L490 165" {line}/>{buttons}'
    if kind == "lapel":
        return f'<path d="M400 230 V900 M310 130 L345 330 L400 230 L455 330 L490 130" {line}/>'
    if kind == "seam":
        return f'<path d="M255 150 H545 M400 150 V330 M285 150 Q300 230 250 250 M515 150 Q500 230 550 250" {line}/>'
    if kind == "crease":
        return f'<path d="M250 140 H550 M305 140 L290 930 M495 140 L510 930" {line}/>'
    return ""


def svg(fill: str, shape: str, kind: str) -> str:
    shadow = '<filter id="s" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="14"/></filter>'
    if shape == SHOE:
        sole = "#E9E2D4" if fill < "#8" else "#B9B2A4"
        one = (
            f'<path d="{SHOE}" fill="#000" opacity="0.22" filter="url(#s)" transform="translate(6 16)"/>'
            f'<path d="{SHOE}" fill="{fill}"/>'
            f'<path d="M40 180 H400 V205 H40 Z" fill="{sole}"/>'
            '<path d="M150 70 L230 125 M175 62 L250 118" stroke="#000" stroke-opacity="0.2" stroke-width="5"/>'
        )
        body = f'<g transform="translate(120 250) scale(1.3)">{one}</g><g transform="translate(180 560) scale(1.3)">{one}</g>'
    else:
        body = (
            f'<path d="{shape}" fill="#000" opacity="0.22" filter="url(#s)" transform="translate(8 18)"/>'
            f'<clipPath id="c"><path d="{shape}"/></clipPath>'
            f'<path d="{shape}" fill="{fill}"/>'
            f'<g clip-path="url(#c)">{details(kind, fill)}'
            '<rect x="0" y="0" width="800" height="1000" fill="url(#g)"/></g>'
        )
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" width="1000" height="1000" viewBox="-100 0 1000 1000">'
        f'<defs>{shadow}<linearGradient id="g" x1="0" x2="1"><stop offset="0" stop-color="#000" stop-opacity="0.10"/>'
        '<stop offset="0.5" stop-color="#fff" stop-opacity="0.05"/><stop offset="1" stop-color="#000" stop-opacity="0.12"/>'
        '</linearGradient></defs><rect x="-100" width="1000" height="1000" fill="#CFC8BC"/>'
        f"{body}</svg>"
    )


def call(method: str, path: str, payload: dict | None = None) -> dict:
    request = urllib.request.Request(
        API + path,
        method=method,
        data=json.dumps(payload).encode() if payload is not None else None,
        headers={"X-User-Id": USER, "Content-Type": "application/json"},
    )
    while True:
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                body = json.load(response)
            break
        except urllib.error.HTTPError as error:
            if error.code != 429:
                raise
            time.sleep(15)  # per-minute API limit on the dev stack
    return body.get("data", body) if isinstance(body, dict) and "code" in body else body


def upload(jpeg: Path) -> str:
    presign = call("POST", "/v1/uploads/presign", {"file_name": jpeg.name, "content_type": "image/jpeg"})
    target, public = urllib.parse.urlsplit(presign["upload_url"]), urllib.parse.urlsplit(presign["file_url"])
    if target.hostname in INTERNAL_HOSTS:
        target = target._replace(scheme=public.scheme, netloc=public.netloc)
    args = ["curl", "-fsS", "-o", "/dev/null"]
    for key, value in (presign.get("fields") or {}).items():
        args += ["-F", f"{key}={value}"]
    args += ["-F", f"file=@{jpeg};type=image/jpeg", urllib.parse.urlunsplit(target)]
    subprocess.run(args, check=True)
    return presign["file_url"]


def main() -> None:
    if "--reset" in sys.argv:
        for item in call("GET", "/v1/wardrobe-items?limit=100")["items"]:
            call("DELETE", f"/v1/wardrobe-items/{item['item_id']}")
    current = call("GET", "/v1/wardrobe-items?limit=100")["items"]
    existing = {item["title"] for item in current}
    for item in current:  # wardrobes seeded before attributes existed
        if item["title"] in ATTRIBUTES and item.get("formality_score") is None:
            set_attributes(item["item_id"], item["title"])
    with tempfile.TemporaryDirectory() as raw:
        work = Path(raw)
        for title, category, color, fill, shape, kind in WARDROBE:
            if title in existing:
                continue
            source = work / f"{uuid.uuid4().hex}.svg"
            source.write_text(svg(fill, shape, kind))
            subprocess.run(["qlmanage", "-t", "-s", "1000", "-o", str(work), str(source)], check=True, capture_output=True)
            jpeg = source.with_suffix(".jpg")
            subprocess.run(
                ["sips", "-s", "format", "jpeg", f"{source}.png", "--out", str(jpeg)], check=True, capture_output=True
            )
            task = call(
                "POST", "/v1/import-tasks", {"input_type": "image", "source_type": "album", "image_url": upload(jpeg)}
            )["task_id"]
            for _ in range(60):
                status = call("GET", f"/v1/import-tasks/{task}")["status"]
                if status in ("waiting_confirm", "failed"):
                    break
                time.sleep(1)
            if status != "waiting_confirm":
                sys.exit(f"import of {title} ended in {status}")
            created = call(
                "POST", f"/v1/import-tasks/{task}/confirm", {"title": title, "category": category, "color_main": color}
            )
            set_attributes(created["item_id"], title)
            print("imported", title)


if __name__ == "__main__":
    main()
