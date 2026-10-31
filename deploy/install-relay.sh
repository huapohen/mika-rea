#!/bin/bash
# Run on the authorized Ubuntu server after uploading server.py and relay.json.
set -euo pipefail
cd "$(dirname "$0")"
getent passwd mika-rea >/dev/null || sudo -n useradd --system --no-create-home --shell /usr/sbin/nologin mika-rea
sudo -n install -d -m 755 /opt/mika-rea
sudo -n install -d -m 750 -o root -g mika-rea /etc/mika-rea
sudo -n install -m 644 server.py /opt/mika-rea/server.py
sudo -n install -m 640 -o root -g mika-rea relay.json /etc/mika-rea/relay.json
sudo -n tee /etc/systemd/system/mika-rea.service >/dev/null <<'SERVICE'
[Unit]
Description=Mika REA authenticated phone relay
After=network-online.target
Wants=network-online.target
[Service]
User=mika-rea
Group=mika-rea
ExecStart=/usr/bin/python3 /opt/mika-rea/server.py --config /etc/mika-rea/relay.json --host 127.0.0.1 --port 8787
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
MemoryMax=192M
TasksMax=128
[Install]
WantedBy=multi-user.target
SERVICE
sudo -n systemctl daemon-reload
sudo -n systemctl enable --now mika-rea
sudo -n systemctl restart mika-rea
sudo -n python3 - <<'PY'
from pathlib import Path
import time
p=Path('/etc/caddy/Caddyfile'); text=p.read_text()
if 'handle_path /mika-rea/*' not in text:
 marker='qinziduihua.com, www.qinziduihua.com {'
 if text.count(marker)!=1:raise SystemExit('Unexpected Caddyfile; refusing to edit')
 backup=p.with_name('Caddyfile.mika-rea-backup-'+str(int(time.time())));backup.write_text(text)
 routes='''
	handle /mika-rea {
		redir /mika-rea/ 308
	}
	handle_path /mika-rea/* {
		request_body {
			max_size 2MB
		}
		reverse_proxy 127.0.0.1:8787
	}
'''
 p.write_text(text.replace(marker,marker+routes))
 print('Caddy route added; original configuration backed up.')
PY
sudo -n caddy validate --config /etc/caddy/Caddyfile
sudo -n systemctl reload caddy
sudo -n systemctl is-active mika-rea
