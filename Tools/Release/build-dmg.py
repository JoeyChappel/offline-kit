"""Package the approved forest installer without UI scripting or changing Finder preferences."""
import argparse
from pathlib import Path
from dmgbuild import build_dmg

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--stage', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--volume-name', default='Offline Kit')
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
stage = args.stage.resolve()
app = stage/'Offline Kit.app'
guide = stage/'Start Here.pdf'
background = root/'Tools/Release/Artwork/forest-install.png'
for file in [app, guide, background]:
    if not file.exists():
        parser.error(f'Missing packaging input: {file}')
args.output.parent.mkdir(parents=True, exist_ok=True)
build_dmg(str(args.output.resolve()), args.volume_name, settings={
    'format': 'UDZO',
    'filesystem': 'HFS+',
    'files': [str(app), str(guide)],
    'symlinks': {'Applications': '/Applications'},
    'background': str(background),
    # 560 points of artwork plus the 32-point title bar.
    'window_rect': ((180, 140), (720, 592)),
    'default_view': 'icon-view',
    'icon_locations': {'Offline Kit.app': (180, 225), 'Applications': (540, 225), 'Start Here.pdf': (360, 395)},
    'icon_size': 112,
    'text_size': 14,
    'label_pos': 'bottom',
    'show_toolbar': False,
    'show_status_bar': False,
    'show_sidebar': False,
    'show_pathbar': False,
    'show_tab_view': False,
    'show_item_info': False,
    'show_icon_preview': False,
    'hide_extensions': ['Offline Kit.app', 'Start Here.pdf'],
    'arrange_by': None,
    'include_icon_view_settings': True,
    # A single-resolution background: Finder on macOS 26 zooms a Retina TIFF to twice its size.
}, lookForHiDPI=False)
print(f'Packaged forest installer: {args.output.resolve()}')
