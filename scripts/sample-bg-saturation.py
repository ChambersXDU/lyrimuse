#!/usr/bin/env python3
"""Usage: python3 scripts/sample-bg-saturation.py <image.png> [--grid COLSxROWS] [--x0 FRAC] [--x1 FRAC] [--y0 FRAC] [--y1 FRAC]"""

import struct
import sys
import zlib

def read_png(path):
    with open(path, "rb") as f:
        data = f.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG file")
    pos = 8
    width = height = bit_depth = color_type = None
    idat = b""
    while pos < len(data):
        length = struct.unpack(">I", data[pos : pos + 4])[0]
        ctype = data[pos + 4 : pos + 8]
        chunk = data[pos + 8 : pos + 8 + length]
        if ctype == b"IHDR":
            width, height, bit_depth, color_type = struct.unpack(">IIBB", chunk[:10])
        elif ctype == b"IDAT":
            idat += chunk
        elif ctype == b"IEND":
            break
        pos += 12 + length
    if bit_depth != 8 or color_type not in (2, 6):
        raise ValueError(f"unsupported PNG: bit_depth={bit_depth} color_type={color_type} (need 8-bit RGB/RGBA)")
    channels = 4 if color_type == 6 else 3
    raw = zlib.decompress(idat)
    stride = width * channels
    rows = []
    prev = bytearray(stride)
    off = 0
    for _ in range(height):
        filt = raw[off]
        off += 1
        line = bytearray(raw[off : off + stride])
        off += stride

        def paeth(a, b, c):
            p = a + b - c
            pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
            if pa <= pb and pa <= pc:
                return a
            if pb <= pc:
                return b
            return c

        for i in range(stride):
            a = line[i - channels] if i >= channels else 0
            b = prev[i]
            c = prev[i - channels] if i >= channels else 0
            if filt == 1:
                line[i] = (line[i] + a) & 0xFF
            elif filt == 2:
                line[i] = (line[i] + b) & 0xFF
            elif filt == 3:
                line[i] = (line[i] + (a + b) // 2) & 0xFF
            elif filt == 4:
                line[i] = (line[i] + paeth(a, b, c)) & 0xFF
        rows.append(bytes(line))
        prev = line
    return width, height, channels, rows

def rgb_to_hsv(r, g, b):
    r, g, b = r / 255, g / 255, b / 255
    mx, mn = max(r, g, b), min(r, g, b)
    d = mx - mn
    if d == 0:
        h = 0.0
    elif mx == r:
        h = 60 * (((g - b) / d) % 6)
    elif mx == g:
        h = 60 * (((b - r) / d) + 2)
    else:
        h = 60 * (((r - g) / d) + 4)
    s = 0.0 if mx == 0 else d / mx
    return h, s, mx

def pixel(rows, channels, x, y):
    o = x * channels
    row = rows[y]
    return row[o], row[o + 1], row[o + 2]

def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        sys.exit(1)
    path = args[0]
    cols = rows_n = 5
    x0, x1, y0, y1 = 0.15, 0.9, 0.15, 0.9
    i = 1
    while i < len(args):
        if args[i] == "--grid":
            cols, rows_n = map(int, args[i + 1].split("x"))
            i += 2
        elif args[i] == "--x0":
            x0 = float(args[i + 1]); i += 2
        elif args[i] == "--x1":
            x1 = float(args[i + 1]); i += 2
        elif args[i] == "--y0":
            y0 = float(args[i + 1]); i += 2
        elif args[i] == "--y1":
            y1 = float(args[i + 1]); i += 2
        else:
            i += 1

    width, height, channels, rowdata = read_png(path)
    sats = []
    print(f"{path}  ({width}x{height})")
    for gy in range(rows_n):
        fy = y0 + (y1 - y0) * gy / max(1, rows_n - 1)
        y = min(height - 1, int(fy * height))
        line = []
        for gx in range(cols):
            fx = x0 + (x1 - x0) * gx / max(1, cols - 1)
            x = min(width - 1, int(fx * width))
            r, g, b = pixel(rowdata, channels, x, y)
            h, s, v = rgb_to_hsv(r, g, b)
            sats.append(s)
            line.append(f"h={h:5.0f} s={s:.2f}")
        print("  " + "  ".join(line))

    sats.sort()
    n = len(sats)
    median = sats[n // 2]
    p75 = sats[int(n * 0.75)]
    print(f"\nn={n}  min={sats[0]:.3f}  median={median:.3f}  p75={p75:.3f}  max={sats[-1]:.3f}")

if __name__ == "__main__":
    main()
