# EPITA PIE VM

- `epita-pie-virtualbox.ova`: VirtualBox (File > Import Appliance)
- `epita-pie-vmware.ova`: VMware (File > Open)

Verify: `sha256sum -c SHA256SUMS` (Windows: `Get-FileHash <file>.ova`)

Boots straight into a local session: user `epita`, no password,
`/home/epita` persists. For your real EPITA files, log in on the AFS
window at startup, or run `afs`. Works from any network, no VPN.

Defaults: 6 GB RAM, 4 CPUs, NAT.

First boot, in a terminal, update `afs`:
`curl -fsSL https://raw.githubusercontent.com/KazeTachinuu/epita-pie-vm/master/vm/hotfix.sh | sh`
AFS stuck or not reconnecting: `afs off`, then `afs`.

Tip: take a snapshot right after importing (both hypervisors, one
click). That is your factory reset forever.
