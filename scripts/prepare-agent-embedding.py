#!/usr/bin/env python3
"""Copy the existing local embedding model into the managed index data directory."""

import argparse
import json
from pathlib import Path
import re
import shutil


def prepare(source: Path, destination: Path, configuration: Path) -> dict:
    """Preserve the original cache and copy only the configured manifest and its blobs.

    Args:
        source: Existing Ollama model directory containing manifests and blobs.
        destination: New private model directory; existing destinations are refused.
        configuration: Non-secret packaged embedding settings.

    Returns:
        A receipt with local model and copied-byte counts.

    Raises:
        ValueError: The manifest, digest, or recorded file size is invalid.
        FileExistsError: The destination has already been prepared.
    """
    config = json.loads(configuration.read_text())
    manifest_path = Path(config['manifestRelativePath'])
    if manifest_path.is_absolute() or '..' in manifest_path.parts:
        raise ValueError('Model manifest must be a relative path inside the cache')
    manifest = source / manifest_path
    if manifest.stat().st_size > 65_536:
        raise ValueError('Model manifest is too large')
    data = json.loads(manifest.read_text())
    blobs = [data['config'], *data['layers']]
    copies = {manifest_path: manifest.stat().st_size}
    for blob in blobs:
        digest = blob['digest']
        if not re.fullmatch(r'sha256:[a-f0-9]{64}', digest):
            raise ValueError('Unsupported model digest')
        relative = Path('blobs') / digest.replace(':', '-')
        if blob['size'] <= 0 or (source / relative).stat().st_size != blob['size']:
            raise ValueError('Model file is missing or has an unexpected size')
        copies[relative] = blob['size']
    destination.mkdir(parents=True, mode=0o700, exist_ok=False)
    for relative, size in copies.items():
        target = destination / relative
        target.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
        shutil.copyfile(source / relative, target)
        target.chmod(0o600)
        if target.stat().st_size != size:
            raise ValueError('Copied model file has an unexpected size')
    receipt = {'source_preserved': True, 'downloaded': False,
               'files': len(copies), 'bytes': sum(copies.values())}
    (destination / 'preparation-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    return receipt


def main() -> None:
    """Prepare the installed embedding cache from an explicitly selected local source."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-models', type=Path, required=True)
    parser.add_argument('--destination-models', type=Path,
                        default=Path.home() / 'Library/Application Support/mytype/agent-index/models')
    parser.add_argument('--configuration', type=Path,
                        default=Path(__file__).resolve().parents[1] / 'Type4Me/Resources/AgentEmbeddingConfig.json')
    args = parser.parse_args()
    print(json.dumps(prepare(args.source_models, args.destination_models, args.configuration), indent=2))


if __name__ == '__main__':
    main()
