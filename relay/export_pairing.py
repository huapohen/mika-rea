"""Export separate phone pairing files without displaying credentials."""
import argparse
import json
import os
import re
from pathlib import Path
from urllib.parse import urlsplit


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', required=True)
    parser.add_argument('--device', required=True)
    parser.add_argument('--relay', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    url = urlsplit(args.relay)
    if (url.scheme != 'https' or not url.hostname or url.username or url.password
            or url.query or url.fragment or not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', args.device)):
        parser.error('Use an HTTPS relay and a valid device ID')
    devices = json.loads(Path(args.config).read_text())['devices']
    if args.device not in devices:
        parser.error('Device not found')
    pair = devices[args.device]
    platform = pair.get('platform', 'android')
    if platform not in ('android', 'ios'):
        parser.error('Unsupported platform')
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True, mode=0o700)
    if any((output / (role + '.json')).exists() for role in ('client', 'agent')):
        parser.error('Pairing output already exists; choose a new private directory')
    for role in ('client', 'agent'):
        value = {'role': role, 'platform': platform, 'device': args.device,
                 'relay': args.relay.rstrip('/'), role + '_token': pair[role + '_token']}
        # O_EXCL prevents replacing a previously shared pairing accidentally.
        descriptor = os.open(output / (role + '.json'), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        with os.fdopen(descriptor, 'w') as file:
            json.dump(value, file)
    print('Separate client.json and agent.json created; keep each with its intended device.')


if __name__ == '__main__':
    main()
