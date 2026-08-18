# EPITA PIE VM

- `epita-pie-virtualbox.ova`: VirtualBox (File > Import Appliance)
- `epita-pie-vmware.ova`: VMware (File > Open)

Verify: `sha256sum -c SHA256SUMS`

Boots straight into a local session: user `epita`, no password,
`/home/epita` persists. For your real EPITA files, log in on the AFS
window at startup, or run `afs`. Works from any network, no VPN.

Defaults: 6 GB RAM, 4 CPUs, NAT. AFS mount acting up? `fusermount3 -u
~/afs`, then `afs`.

Tip: take a snapshot right after importing (both hypervisors, one
click). That is your factory reset forever.
