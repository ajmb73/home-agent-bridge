#!/usr/bin/env python3
"""
Organize flat music files into Artist/Album/Track - Title.ext structure.
Reads ID3 tags via mutagen, moves files to proper folder hierarchy.

Usage:
  python3 organize_music.py              # dry-run (shows what would happen)
  python3 organize_music.py --execute    # actually move files
  python3 organize_music.py --source /mnt/nas/Ale Music  # target specific folder
"""

import os
import sys
import re
import shutil
import argparse
from collections import defaultdict
from pathlib import Path

try:
    import mutagen
except ImportError:
    print("mutagen not installed. Run: pip3 install mutagen")
    sys.exit(1)

# Audio extensions we handle
AUDIO_EXTS = {'.mp3', '.flac', '.m4a', '.wav', '.ogg', '.aac', '.wma', '.opus'}
# Companion files that should travel with their audio file
COMPANION_EXTS = {'.lrc', '.jpg', '.jpeg', '.png', '.gif', '.cue', '.log', '.m3u', '.nfo'}

# Folders to skip entirely
SKIP_FOLDERS = {
    'Well - More Music from Ale',  # still being copied
    'The Warning',                  # already organized
    '#recycle',                     # NAS system folder
}

def sanitize(name: str) -> str:
    """Clean a string for use as a filesystem name."""
    if not name:
        return "Unknown"
    # Replace characters Windows/Linux can't handle
    name = re.sub(r'[<>:"/\\|?*]', '_', name)
    # Collapse multiple spaces/underscores
    name = re.sub(r'\s+', ' ', name).strip()
    # Remove leading/trailing dots and spaces
    name = name.strip('. ')
    return name or "Unknown"


def read_tags(filepath: str) -> dict:
    """Extract artist, album, title, track, date from audio file tags."""
    result = {'artist': 'Unknown Artist', 'album': 'Unknown Album',
              'title': None, 'track': '', 'date': '', 'has_tags': False}
    try:
        audio = mutagen.File(filepath, easy=True)
        if audio is None:
            # Fallback: try without easy=True for formats mutagen struggles with
            audio = mutagen.File(filepath)
        if audio is None:
            result['title'] = Path(filepath).stem
            return result

        # Artist - try multiple tag names
        artist = None
        for tag in ('artist', 'albumartist', 'Band', '©ART'):
            val = audio.get(tag)
            if val:
                if isinstance(val, list):
                    val = val[0]
                artist = str(val).strip()
                if artist:
                    break
        result['artist'] = artist or 'Unknown Artist'

        # Album
        album = None
        for tag in ('album', '©alb'):
            val = audio.get(tag)
            if val:
                if isinstance(val, list):
                    val = val[0]
                album = str(val).strip()
                if album:
                    break
        result['album'] = album or 'Unknown Album'

        # Title
        title = None
        for tag in ('title', '©nam'):
            val = audio.get(tag)
            if val:
                if isinstance(val, list):
                    val = val[0]
                title = str(val).strip()
                if title:
                    break
        result['title'] = title or Path(filepath).stem

        # Track number
        track = audio.get('tracknumber')
        if track:
            t = str(track[0] if isinstance(track, list) else track)
            # Handle "2/17" -> "2", "02" -> "02"
            t = t.split('/')[0].strip()
            result['track'] = t.zfill(2) if t.isdigit() else t
        else:
            # Try 'tracknumber' or 'trck'
            for tag in ('track', 'trck', '©trk'):
                val = audio.get(tag)
                if val:
                    t = str(val[0] if isinstance(val, list) else val)
                    if t.isdigit():
                        result['track'] = t.zfill(2)
                        break

        # Date
        for tag in ('date', 'year', 'originaldate', '©day'):
            val = audio.get(tag)
            if val:
                d = str(val[0] if isinstance(val, list) else val).strip()
                if d:
                    # Extract just the year
                    m = re.match(r'(\d{4})', d)
                    result['date'] = m.group(1) if m else d
                    break

        result['has_tags'] = True

    except Exception as e:
        result['title'] = Path(filepath).stem

    if not result['title']:
        result['title'] = Path(filepath).stem
    return result


def build_target_path(base_dir: str, tags: dict, ext: str) -> str:
    """Build target path: Artist/Album (Year)/Track - Title.ext"""
    artist = sanitize(tags['artist'])
    album = sanitize(tags['album'])

    # Append year to album folder if available
    if tags['date']:
        album_folder = f"{album} ({tags['date']})"
    else:
        album_folder = album

    # Build filename
    track_str = tags['track']
    title = sanitize(tags['title'] or Path(tags.get('_path', 'unknown')).stem)

    if track_str and track_str.isdigit():
        filename = f"{track_str} - {title}{ext}"
    else:
        filename = f"{title}{ext}"

    return os.path.join(base_dir, artist, album_folder, filename)


def find_companions(filepath: str) -> list:
    """Find companion files (.lrc, cover art, etc.) for a given audio file."""
    companions = []
    base = os.path.splitext(filepath)[0]
    dirname = os.path.dirname(filepath)

    for ext in COMPANION_EXTS:
        companion = base + ext
        if os.path.exists(companion):
            companions.append(companion)
        # Also check same-name files in the same directory
        alt = os.path.join(dirname, Path(base).name + ext)
        if os.path.exists(alt) and alt not in companions:
            companions.append(alt)

    return companions


def organize_folder(source_dir: str, target_base: str, execute: bool = False) -> dict:
    """Process all audio files in source_dir, moving to target_base/Artist/Album/"""
    stats = {'processed': 0, 'skipped': 0, 'errors': 0, 'moved': 0,
             'duplicates': 0, 'already_exists': 0, 'files': []}

    if not os.path.isdir(source_dir):
        print(f"  ⚠️  Source not found: {source_dir}")
        return stats

    folder_name = os.path.basename(source_dir)
    audio_files = []
    for f in os.listdir(source_dir):
        ext = os.path.splitext(f)[1].lower()
        if ext in AUDIO_EXTS:
            audio_files.append(f)

    if not audio_files:
        print(f"  📂 {folder_name}/ — no audio files found")
        return stats

    audio_files.sort()
    print(f"\n  📂 {folder_name}/ — {len(audio_files)} files")

    for filename in audio_files:
        filepath = os.path.join(source_dir, filename)
        ext = os.path.splitext(filename)[1].lower()
        stats['processed'] += 1

        try:
            tags = read_tags(filepath)
            tags['_path'] = filepath
            target = build_target_path(target_base, tags, ext)

            # Determine action
            if os.path.exists(target):
                source_size = os.path.getsize(filepath)
                target_size = os.path.getsize(target)
                if source_size > target_size:
                    action = "REPLACE (larger)"
                elif source_size == target_size and os.path.normpath(filepath) != os.path.normpath(target):
                    action = "DUPLICATE (same size)"
                    stats['duplicates'] += 1
                elif source_size == target_size:
                    action = "SKIP (same file)"
                    stats['skipped'] += 1
                else:
                    action = "SKIP (existing larger)"
                    stats['already_exists'] += 1
            else:
                action = "MOVE"
                if not execute:
                    stats['moved'] += 1

            # Dry-run: just report
            if not execute:
                if stats['processed'] <= 5:
                    print(f"    {'→ DRY':10s} {Path(filepath).name:45s} → {target}")
                stats['files'].append((filepath, target, action))
                continue

            # Execute mode: actually move the file
            if action.startswith("REPLACE"):
                os.remove(target)
            elif action.startswith("SKIP") or action.startswith("DUPLICATE"):
                stats['files'].append((filepath, target, action))
                continue

            # Move the file
            os.makedirs(os.path.dirname(target), exist_ok=True)
            shutil.move(filepath, target)

            # Move companion files
            for comp in find_companions(filepath):
                comp_target = os.path.join(os.path.dirname(target), os.path.basename(comp))
                shutil.move(comp, comp_target)

            stats['moved'] += 1
            stats['files'].append((filepath, target, "MOVED"))

        except Exception as e:
            stats['errors'] += 1
            print(f"    ❌ {filename}: {e}")

    # After all files processed, show totals
    if stats['processed'] > 5:
        remaining = stats['processed'] - 5
        print(f"    ... and {remaining} more files")

    return stats


def main():
    parser = argparse.ArgumentParser(description="Organize music files into Artist/Album structure")
    parser.add_argument('--execute', action='store_true', help="Actually move files (dry-run by default)")
    parser.add_argument('--source', '-s', help="Process only this source folder (relative to /mnt/nas/)")
    args = parser.parse_args()

    base_dir = '/mnt/nas'

    if not os.path.isdir(base_dir):
        print(f"❌ NAS mount not found at {base_dir}")
        print("   Mount it first: sudo mount -t cifs //nas.home/Music /mnt/nas -o ...")
        sys.exit(1)

    # Determine source folders
    if args.source:
        source_folders = [args.source]
    else:
        source_folders = sorted([
            os.path.join(base_dir, d)
            for d in os.listdir(base_dir)
            if os.path.isdir(os.path.join(base_dir, d))
            and d not in SKIP_FOLDERS
            and not d.startswith('.')
        ])

    mode = "DRY-RUN" if not args.execute else "EXECUTE"
    print(f"{'='*60}")
    print(f"  Music Organizer — {mode}")
    print(f"{'='*60}")

    total = {'processed': 0, 'moved': 0, 'skipped': 0, 'errors': 0,
             'duplicates': 0, 'already_exists': 0}

    for folder in source_folders:
        fname = os.path.basename(folder)
        if fname in SKIP_FOLDERS:
            continue

        stats = organize_folder(folder, base_dir, execute=args.execute)
        for k in total:
            total[k] += stats[k]

    # Print summary
    print(f"\n{'='*60}")
    print(f"  SUMMARY ({mode})")
    print(f"{'='*60}")
    print(f"  Files processed:     {total['processed']}")
    print(f"  Would move:          {total['moved']}")
    print(f"  Duplicates found:    {total['duplicates']}")
    print(f"  Skipped (existing):  {total['already_exists']}")
    print(f"  Errors:              {total['errors']}")

    if not args.execute and total['moved'] > 0:
        print(f"\n  ▶ Run with --execute to apply these changes")

    if args.execute:
        # Clean up empty source folders
        print(f"\n  Cleaning up empty source folders...")
        for folder in source_folders:
            fname = os.path.basename(folder)
            if fname in SKIP_FOLDERS:
                continue
            try:
                remaining = [f for f in os.listdir(folder) if not f.startswith('.')]
                if not remaining:
                    os.rmdir(folder)
                    print(f"    ✓ Removed empty: {fname}/")
                else:
                    print(f"    ⚠️  Not empty: {fname}/ — {len(remaining)} non-audio files remain")
            except OSError as e:
                print(f"    ⚠️  Could not remove {fname}/: {e}")


if __name__ == '__main__':
    main()
