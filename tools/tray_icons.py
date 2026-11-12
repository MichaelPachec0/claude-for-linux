#!/usr/bin/env python3
"""Derive Claude's Linux tray icons from the macOS template icon.

The macOS DMG only ships TrayIconTemplate*.png (a black glyph with alpha).
Patch 08b selects TrayIconLinux.png / TrayIconLinux-Dark.png on Linux, which
upstream only ships in its Linux build, so without them nativeImage.createFromPath
returns an empty image and the tray shows a placeholder.

The template is already the light-panel (dark glyph) icon; the dark-panel icon
is the same glyph with its RGB inverted and alpha preserved.

Usage: tray_icons.py <TrayIconTemplate.png> <output_dir>
"""
import os
import struct
import sys
import zlib

PNG_SIG = b'\x89PNG\r\n\x1a\n'


def read_png(path):
    data = open(path, 'rb').read()
    if data[:8] != PNG_SIG:
        raise SystemExit(f'Error: {path} is not a PNG')

    pos, ihdr, idat, palette = 8, None, b'', None
    while pos < len(data):
        length = struct.unpack('>I', data[pos:pos + 4])[0]
        ctype = data[pos + 4:pos + 8]
        chunk = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if ctype == b'IHDR':
            ihdr = struct.unpack('>IIBBBBB', chunk)
        elif ctype == b'IDAT':
            idat += chunk
        elif ctype == b'PLTE':
            palette = chunk
        elif ctype == b'IEND':
            break

    if ihdr is None:
        raise SystemExit(f'Error: {path} has no IHDR')
    width, height, depth, color, _comp, _filter, interlace = ihdr
    if depth != 8 or interlace != 0:
        raise SystemExit(f'Error: unsupported PNG (depth={depth}, interlace={interlace})')
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}.get(color)
    if channels is None:
        raise SystemExit(f'Error: unsupported PNG color type {color}')

    raw = zlib.decompress(idat)
    stride = width * channels
    rows, prev, i = [], bytearray(stride), 0
    for _ in range(height):
        filt = raw[i]
        i += 1
        line = bytearray(raw[i:i + stride])
        i += stride
        if filt == 1:
            for x in range(channels, stride):
                line[x] = (line[x] + line[x - channels]) & 0xFF
        elif filt == 2:
            for x in range(stride):
                line[x] = (line[x] + prev[x]) & 0xFF
        elif filt == 3:
            for x in range(stride):
                left = line[x - channels] if x >= channels else 0
                line[x] = (line[x] + ((left + prev[x]) >> 1)) & 0xFF
        elif filt == 4:
            for x in range(stride):
                left = line[x - channels] if x >= channels else 0
                up = prev[x]
                upleft = prev[x - channels] if x >= channels else 0
                p = left + up - upleft
                pa, pb, pc = abs(p - left), abs(p - up), abs(p - upleft)
                pred = left if pa <= pb and pa <= pc else (up if pb <= pc else upleft)
                line[x] = (line[x] + pred) & 0xFF
        elif filt != 0:
            raise SystemExit(f'Error: bad PNG filter {filt}')
        rows.append(bytes(line))
        prev = line

    pixels = []
    for line in rows:
        for x in range(width):
            o = x * channels
            if color == 6:
                r, g, b, a = line[o:o + 4]
            elif color == 2:
                r, g, b = line[o:o + 3]
                a = 255
            elif color == 4:
                r = g = b = line[o]
                a = line[o + 1]
            elif color == 0:
                r = g = b = line[o]
                a = 255
            else:  # palette
                idx = line[o] * 3
                r, g, b = palette[idx:idx + 3]
                a = 255
            pixels.append((r, g, b, a))
    return width, height, pixels


def write_png(path, width, height, pixels):
    raw = b''.join(
        b'\x00' + bytes(v for px in pixels[y * width:(y + 1) * width] for v in px)
        for y in range(height)
    )

    def chunk(kind, data):
        body = kind + data
        return struct.pack('>I', len(data)) + body + struct.pack('>I', zlib.crc32(body) & 0xFFFFFFFF)

    ihdr = struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)
    with open(path, 'wb') as f:
        f.write(PNG_SIG + chunk(b'IHDR', ihdr) + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))


def main():
    if len(sys.argv) != 3:
        raise SystemExit(f'Usage: {sys.argv[0]} <TrayIconTemplate.png> <output_dir>')
    src, outdir = sys.argv[1], sys.argv[2]
    os.makedirs(outdir, exist_ok=True)

    width, height, pixels = read_png(src)

    # Light panel: the template glyph as-is.
    write_png(os.path.join(outdir, 'TrayIconLinux.png'), width, height, pixels)
    # Dark panel: same glyph, inverted RGB, alpha untouched.
    write_png(
        os.path.join(outdir, 'TrayIconLinux-Dark.png'),
        width, height,
        [(255 - r, 255 - g, 255 - b, a) for (r, g, b, a) in pixels],
    )
    print(f'  Generated TrayIconLinux.png and TrayIconLinux-Dark.png ({width}x{height}) from {os.path.basename(src)}')


if __name__ == '__main__':
    main()
