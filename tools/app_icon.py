"""Provide the macOS .icns app icon from macos/Assets/AppIcon.icns (or compile from AppIcon.png)."""
from pathlib import Path
import shutil
import struct
import subprocess

ASSETS_DIR = Path(__file__).resolve().parents[1] / 'macos/Assets'
ICNS_SOURCE = ASSETS_DIR / 'AppIcon.icns'
PNG_SOURCE = ASSETS_DIR / 'AppIcon.png'
SRGB_PROFILE = '/System/Library/ColorSync/Profiles/sRGB Profile.icc'

_ICONSET_SIZES = [
    (16, 'icon_16x16.png'),
    (32, 'icon_16x16@2x.png'),
    (32, 'icon_32x32.png'),
    (64, 'icon_32x32@2x.png'),
    (128, 'icon_128x128.png'),
    (256, 'icon_128x128@2x.png'),
    (256, 'icon_256x256.png'),
    (512, 'icon_256x256@2x.png'),
    (512, 'icon_512x512.png'),
    (1024, 'icon_512x512@2x.png'),
]


def compile_icon(work, resources_dir):
    """Copy or compile Resources/AppIcon.icns and return CFBundleIconFile Info.plist key."""
    work, resources_dir = Path(work), Path(resources_dir)
    resources_dir.mkdir(parents=True, exist_ok=True)
    icns = resources_dir / 'AppIcon.icns'

    if ICNS_SOURCE.is_file():
        assert ICNS_SOURCE.read_bytes()[:4] == b'icns', f'Expected valid .icns file at {ICNS_SOURCE}'
        shutil.copy2(ICNS_SOURCE, icns)
        assert icns.is_file() and icns.stat().st_size > 0
        return {'CFBundleIconFile': 'AppIcon'}

    data = PNG_SOURCE.read_bytes()
    assert data[:8] == b'\x89PNG\r\n\x1a\n'
    width, height = struct.unpack_from('>II', data, 16)
    assert width == height and 1024 <= width <= 8192, 'Expected a >=1024x1024 square icon'

    iconset = work / 'AppIcon.iconset'
    if iconset.exists():
        shutil.rmtree(iconset)
    iconset.mkdir(parents=True, exist_ok=True)
    for px, name in _ICONSET_SIZES:
        subprocess.run(
            ['sips', '--matchTo', SRGB_PROFILE, '-s', 'format', 'png',
             '--resampleHeightWidth', str(px), str(px),
             str(PNG_SOURCE), '--out', str(iconset / name)],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
    subprocess.run(['iconutil', '-c', 'icns', str(iconset), '-o', str(icns)], check=True)
    assert icns.is_file() and icns.stat().st_size > 0
    return {'CFBundleIconFile': 'AppIcon'}
