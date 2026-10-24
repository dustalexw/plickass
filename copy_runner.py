"""Non-interactive runner used by the Mac app: python3 copy_runner.py <plexamp_offline_dir> <destination>"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from correlate import PlexampCorrelate
from plexampDownloadCopier import PlexampDownloadCopier


def main():
    if len(sys.argv) != 3:
        print('usage: copy_runner.py <plexamp_offline_dir> <destination>')
        return 2
    src, dst = sys.argv[1], sys.argv[2]
    # Build the objects without their interactive prompts.
    correlator = PlexampCorrelate.__new__(PlexampCorrelate)
    correlator.appdir = src
    copier = PlexampDownloadCopier.__new__(PlexampDownloadCopier)
    copier.correlator = correlator
    copier.savepath = dst
    try:
        # Read the index once, report the total for the progress bar, then copy from that result.
        files = correlator.correlate()
        total = sum(len(album['tracks']) for albums in files.values() for album in albums.values())
        print(f'__TOTAL__ {total}')
        correlator.correlate = lambda: files
        copier.copy()
    except Exception as e:
        print(f'ERROR: {type(e).__name__}: {e}')
        return 1
    return 0


if __name__ == '__main__':
    sys.stdout.reconfigure(line_buffering=True)
    sys.exit(main())
