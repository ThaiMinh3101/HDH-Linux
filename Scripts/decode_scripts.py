#!/usr/bin/env python3
"""Decode Scripts.rvdata2 (RPG Maker VX Ace) — Marshal 4.8 + zlib.
Dùng để đọc script game người dùng tự import (bước chẩn đoán M7).
Không phải code engine — chỉ là công cụ đọc dữ liệu.
"""
import sys
import zlib
import struct

def read_varint(data, pos):
    """Ruby Marshal length-prefixed integer (varint)."""
    b = data[pos]
    pos += 1
    if b < 0x80:
        return b, pos
    if b < 0xFE:
        return ((b & 0x7F) << 8) | data[pos], pos + 1
    if b == 0xFE:
        return struct.unpack('>I', data[pos:pos+4])[0], pos + 4
    return struct.unpack('>Q', data[pos:pos+8])[0], pos + 8

def read_marshal(data, pos=0):
    """Decode Ruby Marshal 4.8 value. String returns raw bytes (binary-safe)."""
    if pos >= len(data):
        raise ValueError("EOF")
    t = data[pos]
    pos += 1

    if t == 0x30:  # nil
        return None, pos
    if t == 0x54:  # true
        return True, pos
    if t == 0x46:  # false
        return False, pos
    if t == 0x69:  # Integer
        b = data[pos]
        pos += 1
        if b == 0:
            return 0, pos
        if b > 0x05:
            return b - 0x05, pos
        if b < 0xFB:
            return b - 0x05, pos
        if b == 0x05:
            return struct.unpack('>i', data[pos:pos+4])[0], pos + 4
        if b == 0x06:
            return struct.unpack('>q', data[pos:pos+8])[0], pos + 8
        raise ValueError(f"Unknown integer encoding 0x{b:02x}")
    if t == 0x22:  # String — return raw bytes
        length, pos = read_varint(data, pos)
        s = data[pos:pos+length]
        return s, pos + length
    if t == 0x3A:  # Symbol
        length, pos = read_varint(data, pos)
        s = data[pos:pos+length]
        return s.decode('utf-8', errors='replace'), pos + length
    if t == 0x3B:  # Symbol link
        idx, pos = read_varint(data, pos)
        return f"__symlink_{idx}", pos
    if t == 0x5B:  # Array
        length, pos = read_varint(data, pos)
        arr = []
        for _ in range(length):
            v, pos = read_marshal(data, pos)
            arr.append(v)
        return arr, pos
    if t == 0x7B:  # Hash
        length, pos = read_varint(data, pos)
        h = {}
        for _ in range(length):
            k, pos = read_marshal(data, pos)
            v, pos = read_marshal(data, pos)
            h[k] = v
        return h, pos
    if t == 0x6F:  # Object
        cls, pos = read_marshal(data, pos)
        ivar_count, pos = read_varint(data, pos)
        obj = {"__class__": cls}
        for _ in range(ivar_count):
            name, pos = read_marshal(data, pos)
            val, pos = read_marshal(data, pos)
            obj[name] = val
        return obj, pos
    if t == 0x40:  # Object link
        idx, pos = read_varint(data, pos)
        return f"__objlink_{idx}", pos
    raise ValueError(f"Unknown type 0x{t:02x} at pos {pos-1}")

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 decode_scripts.py <Scripts.rvdata2> [start_id] [end_id]")
        sys.exit(1)
    path = sys.argv[1]
    start_id = int(sys.argv[2]) if len(sys.argv) > 2 else 0
    end_id = int(sys.argv[3]) if len(sys.argv) > 3 else 99999

    with open(path, 'rb') as f:
        data = f.read()

    if data[0] != 0x04 or data[1] != 0x08:
        print("Not Marshal 4.8")
        sys.exit(1)

    root, _ = read_marshal(data, 2)
    if not isinstance(root, list):
        print("Root not array")
        sys.exit(1)

    print(f"Total scripts: {len(root)}")
    for i, script in enumerate(root):
        if not isinstance(script, list) or len(script) != 3:
            continue
        sid = script[0]
        name = script[1]
        comp = script[2]
        if not isinstance(sid, int) or not isinstance(name, str) or not isinstance(comp, bytes):
            continue
        if sid < start_id or sid > end_id:
            continue
        try:
            decompressed = zlib.decompress(comp)
            source = decompressed.decode('utf-8', errors='replace')
            print(f"\n{'='*80}")
            print(f"SCRIPT {sid}: {name} ({len(source)} chars)")
            print(f"{'='*80}")
            print(source)
        except Exception as e:
            print(f"Script {sid} ({name}): zlib error {e}")

if __name__ == '__main__':
    main()