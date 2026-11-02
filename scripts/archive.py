"""Stingray patch archive builder & MurmurHash64A resource hasher for Helldivers 2.

Produces byte-for-byte authentic `9ba626afa44a3aa3.patch_0` archives compatible
with both MDL3 (`mods.discover`) and Bingus Shared Loader (`discover.lua`).
"""
from __future__ import annotations

import struct
from typing import Dict

ARCHIVE = '9ba626afa44a3aa3.patch_0'

_MASK64 = 0xFFFFFFFFFFFFFFFF
_MUL64 = 0xC6A4A7935BD1E995
_SHIFT = 47


def resource_hash(name: str | bytes, seed: int = 0) -> int:
    """Compute Stingray's 64-bit MurmurHash64A of an ASCII resource path."""
    data = name.encode('ascii') if isinstance(name, str) else bytes(name)
    h = (seed ^ ((len(data) * _MUL64) & _MASK64)) & _MASK64
    nblocks = len(data) // 8
    for i in range(nblocks):
        (k,) = struct.unpack_from('<Q', data, i * 8)
        k = (k * _MUL64) & _MASK64
        k ^= k >> _SHIFT
        k = (k * _MUL64) & _MASK64
        h = ((h ^ k) * _MUL64) & _MASK64
    rem = data[nblocks * 8:]
    if rem:
        val = 0
        for idx, b in enumerate(rem):
            val |= b << (8 * idx)
        h = ((h ^ val) * _MUL64) & _MASK64
    h ^= h >> _SHIFT
    h = (h * _MUL64) & _MASK64
    h ^= h >> _SHIFT
    return h


TYPE = resource_hash('lua')  # 0xa14e8dfa2cd117e2


def _align16(n: int) -> int:
    return (n + 15) & ~15


def make_archive(entries: Dict[int, bytes]) -> bytes:
    """Pack `{name_hash_u64: envelope_plus_body}` into a Stingray 0xF0000011 patch archive."""
    if not entries:
        raise ValueError('make_archive requires at least one resource entry')

    # Sort entries by little-endian 8-byte key bytes for deterministic binary layout.
    items = sorted(
        ((struct.pack('<Q', key_u64 & _MASK64), payload) for key_u64, payload in entries.items()),
        key=lambda item: item[0],
    )
    count = len(items)
    type_bytes = struct.pack('<Q', TYPE)

    table_end = 72 + 32 * 1 + 80 * count
    cursor = _align16(table_end)

    file_rows = []
    blobs = []
    for key_bytes, raw in items:
        padded_len = _align16(len(raw))
        file_rows.append(
            key_bytes
            + type_bytes
            + struct.pack('<Q', cursor)
            + (b'\x00' * 32)
            + struct.pack('<QIIII', len(raw), 0, 16, 16, 0)
        )
        blobs.append(raw + (b'\x00' * (padded_len - len(raw))))
        cursor += padded_len

    header = (
        struct.pack('<III', 0xF0000011, 1, count)
        + (b'\x00' * 20)
        + struct.pack('<Q', cursor)
        + (b'\x00' * 32)
    )
    type_row = struct.pack('<Q', 0) + type_bytes + struct.pack('<QII', count, 16, 16)
    pad_after_tables = b'\x00' * (_align16(table_end) - table_end)

    return header + type_row + b''.join(file_rows) + pad_after_tables + b''.join(blobs)
