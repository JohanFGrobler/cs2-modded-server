#!/usr/bin/env python3
"""
Add a map entry to a CS2 game mode map group and (optionally) subscribe to its Workshop ID.

Typical files (global vs custom):
- Global:  game/csgo/gamemodes_server.txt, game/csgo/subscribed_file_ids.txt
- Custom:  custom_files/gamemodes_server.txt, custom_files/subscribed_file_ids.txt

Requirements:
- Python 3.8+

Usage:
  python scripts/add-map.py <group_name> <map_name> [workshop_id] [--custom] [--dry-run] [--position start|end]

Examples:
  python scripts/add-map.py mg_aim aim_ak-colt_CS2 123456789 --custom
  python scripts/add-map.py mg_active de_train --position start
  python scripts/add-map.py mg_active de_dust2 3070284539

Notes:
- Workshop ID is the trailing number from the Workshop URL, e.g.
  https://steamcommunity.com/sharedfiles/filedetails/?id=3070284539 -> 3070284539
- If workshop_id is provided, the map path is written as: workshop/<id>/<map_name>
"""

from __future__ import annotations

import argparse
import pathlib
import shutil
import sys
from typing import Optional, Tuple


class AddMapError(RuntimeError):
    pass


def read_lines(path: pathlib.Path) -> list[str]:
    try:
        return path.read_text(encoding="utf-8", errors="replace").splitlines(keepends=True)
    except FileNotFoundError:
        raise AddMapError(f"Missing file: {path}")


def write_lines(path: pathlib.Path, lines: list[str]) -> None:
    path.write_text("".join(lines), encoding="utf-8")


def backup_file(path: pathlib.Path) -> pathlib.Path:
    backup = path.with_suffix(path.suffix + ".bak")
    shutil.copy2(path, backup)
    return backup


def find_group_and_maps_block(lines: list[str], group_name: str) -> Tuple[int, int, int, str]:
    """
    Returns (group_start_idx, maps_start_idx, maps_end_idx, indent)
    - maps_start_idx points at the first line INSIDE the maps block (after the opening brace)
    - maps_end_idx points at the closing brace line of the maps block
    - indent is the indentation used for map entries
    """
    in_mapgroups = False
    i = 0

    # 1) Find "mapgroups"
    while i < len(lines):
        if lines[i].lstrip().startswith('"mapgroups"'):
            in_mapgroups = True
            break
        i += 1
    if not in_mapgroups:
        raise AddMapError('Could not find a "mapgroups" section.')

    # 2) Walk braces to find the block of mapgroups { ... }
    i += 1
    brace_depth = 0
    while i < len(lines) and "{" not in lines[i]:
        i += 1
    if i >= len(lines):
        raise AddMapError('Malformed "mapgroups" block (missing "{").')
    brace_depth += 1
    i += 1

    # 3) Find the group block by name
    group_start = -1
    while i < len(lines) and brace_depth > 0:
        stripped = lines[i].strip()
        if "{" in lines[i]:
            brace_depth += lines[i].count("{")
        if "}" in lines[i]:
            brace_depth -= lines[i].count("}")

        if stripped.startswith(f'"{group_name}"'):
            group_start = i
            break
        i += 1

    if group_start == -1:
        raise AddMapError(f'Group "{group_name}" not found in mapgroups.')

    # 4) Enter group block
    # find opening "{"
    j = group_start
    while j < len(lines) and "{" not in lines[j]:
        j += 1
    if j >= len(lines):
        raise AddMapError(f'Malformed group "{group_name}" (missing "{{").')

    # Now traverse this group’s braces to locate the "maps" block
    j += 1
    group_brace_depth = 1
    maps_open_line = -1
    while j < len(lines) and group_brace_depth > 0:
        stripped = lines[j].strip()

        # detect maps block header
        if stripped.startswith('"maps"'):
            # find the "{" for maps block
            k = j
            while k < len(lines) and "{" not in lines[k]:
                k += 1
            if k >= len(lines):
                raise AddMapError(f'Malformed "maps" block in group "{group_name}".')
            # maps block starts after the "{"
            maps_block_open = k
            maps_start_idx = maps_block_open + 1

            # find matching "}" for maps
            maps_brace_depth = 1
            m = maps_start_idx
            while m < len(lines) and maps_brace_depth > 0:
                maps_brace_depth += lines[m].count("{")
                maps_brace_depth -= lines[m].count("}")
                if maps_brace_depth == 0:
                    maps_end_idx = m  # points at the closing brace line
                    # indentation: reuse the indentation of existing entries if available, else infer
                    indent = infer_maps_indent(lines, maps_start_idx, maps_end_idx)
                    return (group_start, maps_start_idx, maps_end_idx, indent)
                m += 1
            raise AddMapError(f'Malformed "maps" block in group "{group_name}".')

        # normal brace walk inside group
        if "{" in lines[j]:
            group_brace_depth += lines[j].count("{")
        if "}" in lines[j]:
            group_brace_depth -= lines[j].count("}")
        j += 1

    raise AddMapError(f'No "maps" block found in group "{group_name}".')


def infer_maps_indent(lines: list[str], start_idx: int, end_idx: int) -> str:
    # Look for the first existing map entry to determine indentation
    for i in range(start_idx, end_idx):
        stripped = lines[i].strip()
        if stripped.startswith('"') and '"' in stripped and '\t' in lines[i] or '\t' in lines[i]:
            # likely an entry line; reuse its leading whitespace
            return lines[i][: len(lines[i]) - len(lines[i].lstrip())]
        if stripped.startswith('"') and '\t' not in lines[i]:
            return lines[i][: len(lines[i]) - len(lines[i].lstrip())]
    # Fallback: use 4 tabs similar to Valve files
    return "\t" * 4


def current_maps_in_block(lines: list[str], start_idx: int, end_idx: int) -> list[str]:
    maps = []
    for i in range(start_idx, end_idx):
        stripped = lines[i].strip()
        # Expect lines like:  "de_inferno"  ""
        if stripped.startswith('"') and '"' in stripped:
            key = stripped.split('"')[1]
            maps.append(key)
    return maps


def format_map_key(map_name: str, workshop_id: Optional[str]) -> str:
    if workshop_id:
        return f"workshop/{workshop_id}/{map_name}"
    return map_name


def insert_map(lines: list[str], start_idx: int, end_idx: int, indent: str, map_key: str, position: str) -> None:
    new_line = f'{indent}"{map_key}"\t\t""\n'
    if position == "start":
        lines.insert(start_idx, new_line)
    else:
        # insert just before the closing brace
        lines.insert(end_idx, new_line)


def add_workshop_id(file_path: pathlib.Path, workshop_id: str, dry_run: bool = False) -> bool:
    existing = set()
    if file_path.exists():
        text = file_path.read_text(encoding="utf-8", errors="replace")
        existing = set(line.strip() for line in text.splitlines() if line.strip())

    if workshop_id in existing:
        return False

    if not dry_run:
        file_path.parent.mkdir(parents=True, exist_ok=True)
        with file_path.open("a", encoding="utf-8") as f:
            f.write(f"{workshop_id}\n")
    return True


def add_map_to_group(
    gamemodes_path: pathlib.Path,
    subscribed_file_ids_path: pathlib.Path,
    group_name: str,
    map_name: str,
    workshop_id: Optional[str],
    dry_run: bool,
    position: str,
) -> None:
    lines = read_lines(gamemodes_path)

    map_key = format_map_key(map_name, workshop_id)
    group_start, maps_start, maps_end, indent = find_group_and_maps_block(lines, group_name)
    maps_list = current_maps_in_block(lines, maps_start, maps_end)

    if map_key in maps_list:
        print(f"[skip] Map already present in '{group_name}': {map_key}")
    else:
        # backup then insert
        if not dry_run:
            backup = backup_file(gamemodes_path)
            print(f"[backup] {backup}")
        insert_map(lines, maps_start, maps_end, indent, map_key, position)
        if not dry_run:
            write_lines(gamemodes_path, lines)
        print(f"[ok] Added map to '{group_name}': {map_key} ({'dry-run' if dry_run else 'written'})")

    if workshop_id:
        added = add_workshop_id(subscribed_file_ids_path, workshop_id, dry_run=dry_run)
        if added:
            print(f"[ok] Subscribed Workshop ID {workshop_id} ({'dry-run' if dry_run else 'written'})")
        else:
            print(f"[skip] Workshop ID already present: {workshop_id}")


def resolve_paths(use_custom: bool) -> Tuple[pathlib.Path, pathlib.Path]:
    if use_custom:
        gm = pathlib.Path("custom_files/gamemodes_server.txt")
        sub = pathlib.Path("custom_files/subscribed_file_ids.txt")
    else:
        gm = pathlib.Path("game/csgo/gamemodes_server.txt")
        sub = pathlib.Path("game/csgo/subscribed_file_ids.txt")
    return gm, sub


def main() -> int:
    p = argparse.ArgumentParser(description="Add a map to a given CS2 game mode map group.")
    p.add_argument("group_name", type=str, help="Game mode group (e.g., mg_aim)")
    p.add_argument("map_name", type=str, help="Map name (e.g., aim_ak-colt_CS2)")
    p.add_argument("workshop_id", type=str, nargs="?", default=None, help="Workshop ID (optional)")
    p.add_argument("--custom", action="store_true", help="Use custom file paths instead of global ones.")
    p.add_argument("--dry-run", action="store_true", help="Do not write changes; just print actions.")
    p.add_argument("--position", choices=["start", "end"], default="end", help="Where to insert within the maps block.")
    args = p.parse_args()

    gamemodes_path, subscribed_path = resolve_paths(args.custom)

    # Basic existence checks (for custom mode we require both files to exist; for global,
    # at least gamemodes should exist; subscribed file will be created as needed).
    if args.custom:
        if not gamemodes_path.exists() or not subscribed_path.exists():
            print(
                "Error: Custom files do not exist. Create both "
                f"{gamemodes_path} and {subscribed_path} before using --custom."
            )
            return 1
    else:
        if not gamemodes_path.exists():
            print(f"Error: Missing {gamemodes_path}.")
            return 1

    try:
        add_map_to_group(
            gamemodes_path,
            subscribed_path,
            args.group_name,
            args.map_name,
            args.workshop_id,
            args.dry_run,
            args.position,
        )
        return 0
    except AddMapError as e:
        print(f"Error: {e}")
        return 2


if __name__ == "__main__":
    sys.exit(main())
