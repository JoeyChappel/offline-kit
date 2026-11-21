"""Run against synthetic fixtures only: OFFLINEKIT_HOME must name a disposable test home."""
from pathlib import Path
import os
import subprocess
import tempfile
root = Path(__file__).resolve().parents[2]
assert os.environ.get('OFFLINEKIT_HOME'), 'Set OFFLINEKIT_HOME to an isolated fixture home'
with tempfile.TemporaryDirectory(prefix='offline-kit-media-check-') as directory:
    dest = Path(directory)
    (dest/'HTMLText.swift').write_text('import Foundation\n' + 'enum HTMLText {' + (root/'Sources/Core/Retriever.swift').read_text().split('enum HTMLText {')[1])
    sources = ['Sources/Core/KitSettings.swift', 'Sources/Core/EPUB.swift', 'Sources/App/MediaLibrary.swift',
               'Sources/App/MediaCatalog.swift', 'Sources/App/MediaBrowsing.swift', 'Tools/Tests/MediaCatalogChecks.swift']
    subprocess.run(['swiftc', '-D', 'DEBUG', '-parse-as-library', '-module-cache-path', str(dest/'modules'),
                    *[str(root/s) for s in sources], str(dest/'HTMLText.swift'), '-o', str(dest/'checks')], check=True)
    subprocess.run([str(dest/'checks')], check=True)
