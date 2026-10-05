#!/usr/bin/env python3
"""
vme-guest-run.py - run Invoke-VMwareToVirtio.ps1 inside a Windows VM through the QEMU guest agent.

No WinRM, no network path to the guest, no Windows credentials: qemu-ga runs as SYSTEM and talks to
the host over virtio-serial. Run this on the KVM host that owns the VM.

  ./vme-guest-run.py windows-test-migrated                      # upload, verify, run, show log
  ./vme-guest-run.py windows-test-migrated --wait-reboot        # ...then wait for the VM to come back
  ./vme-guest-run.py windows-test-migrated --script ./other.ps1 --timeout 5400

Multi-NIC static VMs: hand the script each NIC's MAC -> IP from the SOURCE (VMware) VM's Morpheus record, so it can
put the old settings on the right virtio NIC. Nothing has to run inside the VM before migration.
  export MORPHEUS_URL=https://<appliance> MORPHEUS_TOKEN=...
  ./vme-guest-run.py --find-source app01 --insecure                      # list matching servers, pick the VMware one
  ./vme-guest-run.py app01 --source-server-id 123 --insecure --wait-reboot
  ./vme-guest-run.py app01 --nic-map ./app01-nics.json                    # or a map you built yourself

Exit code = the script's exit code inside the guest (0 ok, 1 needs attention), or 2 for host-side errors.
Needs: python3, virsh with access to the domain (root or the libvirt group).
"""
import argparse, base64, hashlib, json, os, ssl, subprocess, sys, time, urllib.parse, urllib.request

__version__ = '1.1.0'

GUEST_DIR = r'C:\ProgramData\VMwareToVirtio'
CHUNK = 32 * 1024  # raw bytes per guest-file-write (base64 ~44 KB per agent message)


class AgentError(Exception):
    pass


def agent(dom, command, arguments=None, timeout=60):
    msg = {'execute': command}
    if arguments is not None:
        msg['arguments'] = arguments
    p = subprocess.run(['virsh', 'qemu-agent-command', dom, json.dumps(msg), '--timeout', str(timeout)],
                       capture_output=True, text=True)
    if p.returncode != 0:
        raise AgentError((p.stderr or p.stdout).strip())
    out = p.stdout.strip()
    return json.loads(out).get('return') if out else None


def guest_exec(dom, path, args, timeout=600, poll=3, show_progress=False):
    """Start a process in the guest and wait for it. Returns (exitcode, stdout, stderr)."""
    pid = agent(dom, 'guest-exec', {'path': path, 'arg': args, 'capture-output': True})['pid']
    deadline = time.time() + timeout
    while True:
        st = agent(dom, 'guest-exec-status', {'pid': pid})
        if st.get('exited'):
            dec = lambda k: base64.b64decode(st.get(k, '')).decode('utf-8', 'replace').replace('\r\n', '\n')
            return st.get('exitcode', -1), dec('out-data'), dec('err-data')
        if time.time() > deadline:
            raise AgentError(f'{path} still running after {timeout}s (guest pid {pid})')
        if show_progress:
            print('.', end='', flush=True)
        time.sleep(poll)


def upload(dom, data, guest_path):
    h = agent(dom, 'guest-file-open', {'path': guest_path, 'mode': 'wb'})
    try:
        for i in range(0, len(data), CHUNK):
            agent(dom, 'guest-file-write', {'handle': h, 'buf-b64': base64.b64encode(data[i:i + CHUNK]).decode()})
    finally:
        agent(dom, 'guest-file-close', {'handle': h})
    return hashlib.sha256(data).hexdigest()


def guest_sha256(dom, guest_path):
    code, out, err = guest_exec(dom, 'certutil.exe', ['-hashfile', guest_path, 'SHA256'], timeout=60)
    for line in out.splitlines():
        hexline = line.strip().replace(' ', '').lower()
        if len(hexline) == 64 and all(c in '0123456789abcdef' for c in hexline):
            return hexline
    raise AgentError(f'certutil gave no hash (exit {code}): {out.strip()} {err.strip()}')


def morpheus_get(base, token, path, insecure=False):
    req = urllib.request.Request(base.rstrip('/') + path, headers={'Authorization': f'Bearer {token}', 'Accept': 'application/json'})
    ctx = ssl._create_unverified_context() if insecure else None
    with urllib.request.urlopen(req, context=ctx, timeout=30) as r:
        return json.loads(r.read().decode())


def nic_map_from_server(server):
    """MAC -> IP for each interface of a Morpheus server record (the source VMware VM)."""
    out = []
    for i in server.get('interfaces') or []:
        mac, ip = (i.get('macAddress') or '').strip(), (i.get('ipAddress') or '').strip()
        if mac:
            out.append({'MacAddress': mac, 'IPAddress': ip, 'Name': i.get('name') or '',
                        'Source': f"morpheus server {server.get('id')} '{server.get('name')}'"})
    return out


def cloud_name(server):
    for k in ('cloud', 'zone'):
        v = server.get(k)
        if isinstance(v, dict) and v.get('name'):
            return v['name']
    return '?'


def find_source(base, token, name, insecure):
    data = morpheus_get(base, token, '/api/servers?max=50&name=' + urllib.parse.quote(name), insecure)
    servers = data.get('servers') or []
    if not servers:
        print(f'No Morpheus servers named {name!r}'); return 1
    print(f'{"ID":>6}  {"Cloud":<24} {"Power":<8} NICs (MAC -> IP)')
    for sv in servers:
        nics = ', '.join(f"{n['MacAddress']} -> {n['IPAddress'] or '-'}" for n in nic_map_from_server(sv)) or '-'
        print(f'{sv.get("id"):>6}  {cloud_name(sv):<24} {str(sv.get("powerState")):<8} {nics}')
    print('\nUse the VMware (source) server ID with --source-server-id.')
    return 0


def wait_reboot(dom, down_within=300, up_within=900):
    print('Waiting for the guest to reboot', end='', flush=True)
    t = time.time()
    while time.time() - t < down_within:          # agent goes away when Windows shuts down
        try:
            agent(dom, 'guest-ping', timeout=5)
        except AgentError:
            break
        print('.', end='', flush=True); time.sleep(5)
    else:
        print('\nGuest agent never went away; reboot may not have happened.'); return False
    t = time.time()
    while time.time() - t < up_within:            # and answers again once Windows is back up
        try:
            agent(dom, 'guest-ping', timeout=5)
            print(' back up.'); return True
        except AgentError:
            print('.', end='', flush=True); time.sleep(10)
    print('\nGuest agent did not come back within the wait window.'); return False


def main():
    ap = argparse.ArgumentParser(description='Run Invoke-VMwareToVirtio.ps1 in a VM via the QEMU guest agent')
    ap.add_argument('domain', nargs='?', help='libvirt domain name (virsh list)')
    ap.add_argument('--script', default='Invoke-VMwareToVirtio.ps1', help='local path of the script to run')
    ap.add_argument('--timeout', type=int, default=3600, help='max seconds to wait for the script')
    ap.add_argument('--wait-reboot', action='store_true', help='after the run, wait for the scheduled reboot')
    ap.add_argument('--nic-map', help='JSON file: [{"MacAddress":..,"IPAddress":..}] to drop into the guest')
    ap.add_argument('--source-server-id', help='Morpheus ID of the SOURCE (VMware) server; builds the NIC map from it')
    ap.add_argument('--find-source', metavar='NAME', help='list Morpheus servers with this name (to find the source ID), then exit')
    ap.add_argument('--morpheus-url', default=os.environ.get('MORPHEUS_URL'), help='Morpheus appliance URL (or MORPHEUS_URL)')
    ap.add_argument('--morpheus-token', default=os.environ.get('MORPHEUS_TOKEN'), help='API token (or MORPHEUS_TOKEN)')
    ap.add_argument('--insecure', action='store_true', help="don't verify the appliance's TLS certificate (self-signed)")
    ap.add_argument('--version', action='version', version=f'%(prog)s {__version__}')
    a = ap.parse_args()

    if a.find_source or a.source_server_id:
        if not (a.morpheus_url and a.morpheus_token):
            print('Set --morpheus-url/--morpheus-token (or MORPHEUS_URL/MORPHEUS_TOKEN)'); return 2
    if a.find_source:
        try:
            return find_source(a.morpheus_url, a.morpheus_token, a.find_source, a.insecure)
        except Exception as e:
            print(f'Morpheus API error: {e}'); return 2
    if not a.domain:
        ap.error('domain is required')

    nic_map = None
    try:
        if a.source_server_id:
            sv = morpheus_get(a.morpheus_url, a.morpheus_token, f'/api/servers/{a.source_server_id}', a.insecure)['server']
            nic_map = nic_map_from_server(sv)
            print(f"NIC map from Morpheus server {sv.get('id')} '{sv.get('name')}' ({cloud_name(sv)}):")
        elif a.nic_map:
            nic_map = json.load(open(a.nic_map))
            print(f'NIC map from {a.nic_map}:')
    except Exception as e:
        print(f'Could not build the NIC map: {e}'); return 2
    if nic_map is not None:
        if not nic_map:
            print('  (no interfaces with a MAC)'); return 2
        for n in nic_map:
            print(f"  {n.get('MacAddress')} -> {n.get('IPAddress') or '-'} {n.get('Name', '')}")
        if not any((n.get('IPAddress') or '').strip() for n in nic_map):
            print('  warning: no IPs in the map; it cannot match anything (was VMware Tools reporting IPs?)')
    guest_path = GUEST_DIR + '\\Invoke-VMwareToVirtio.ps1'

    try:
        agent(a.domain, 'guest-ping', timeout=10)
        print(f'Guest agent on {a.domain}: OK')

        guest_exec(a.domain, 'cmd.exe', ['/c', f'if not exist "{GUEST_DIR}" mkdir "{GUEST_DIR}"'], timeout=60)
        if nic_map is not None:
            upload(a.domain, json.dumps(nic_map, indent=1).encode(), GUEST_DIR + '\\nic-map.json')
            print(f'NIC map -> {GUEST_DIR}\\nic-map.json')
        local_hash = upload(a.domain, open(a.script, 'rb').read(), guest_path)
        remote_hash = guest_sha256(a.domain, guest_path)
        if remote_hash != local_hash:
            print(f'Upload corrupted: local {local_hash}, guest {remote_hash}'); return 2
        print(f'Uploaded {a.script} -> {guest_path} (SHA-256 {local_hash[:16]}..., verified in guest)')

        print('Running', end='', flush=True)
        code, out, err = guest_exec(a.domain, 'powershell.exe',
                                    ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', guest_path],
                                    timeout=a.timeout, poll=5, show_progress=True)
        print(f' finished, exit code {code}\n')
        print(out.rstrip())
        if err.strip():
            print('\n--- stderr ---\n' + err.rstrip())

        if a.wait_reboot and 'Reboot scheduled' in out:
            wait_reboot(a.domain)
        return code
    except AgentError as e:
        print(f'\nGuest agent error: {e}'); return 2
    except FileNotFoundError as e:
        print(f'Not found: {e.filename}'); return 2


if __name__ == '__main__':
    sys.exit(main())
