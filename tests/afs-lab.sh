#!/bin/sh
# afs-lab.sh: a local stand-in for the EPITA gate, to reproduce and test `afs`
# without the CRI network. Needs root, /dev/fuse (Ubuntu/Debian), e.g.:
#   docker run -d --name afslab --privileged -v "$PWD:/repo:ro" ubuntu:24.04 sleep infinity
#   docker exec afslab sh -c 'apt-get update -qq && sh /repo/tests/afs-lab.sh'
#   docker exec afslab sh /repo/tests/afs-test.sh
#
#   tests/afs-lab.sh    KDC (realm CRI.EPITA.FR) + sshd with GSSAPI as
#                       ssh.cri.epita.fr + fake AFS tree
#
# Client user: epita. EPITA login: xlogin, password: pw.
set -eu

REALM=CRI.EPITA.FR GATE=ssh.cri.epita.fr
LOGIN=xlogin PASS=pw
AFS=/afs/cri.epita.fr/user/x/xl/$LOGIN/u

setup() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    sshfs openssh-server krb5-kdc krb5-admin-server krb5-user procps >/dev/null

  # the gate resolves to this machine (no sed -i: bind mount in docker)
  hosts=$(grep -v "[[:space:]]$GATE\$" /etc/hosts || true)
  printf '%s\n127.0.0.1 %s\n' "$hosts" "$GATE" >/etc/hosts

  cat >/etc/krb5.conf <<EOF
[libdefaults]
    default_realm = $REALM
    rdns = false
    dns_canonicalize_hostname = false
[realms]
    $REALM = {
        kdc = 127.0.0.1
    }
EOF
  mkdir -p /etc/krb5kdc
  cat >/etc/krb5kdc/kdc.conf <<EOF
[realms]
    $REALM = {
        kdc_tcp_listen = 88
    }
EOF
  if [ ! -e /var/lib/krb5kdc/principal ]; then
    kdb5_util create -r "$REALM" -s -P masterpw >/dev/null
  fi
  kadmin.local -q "addprinc -pw $PASS $LOGIN" >/dev/null 2>&1 || true
  kadmin.local -q "addprinc -randkey host/$GATE" >/dev/null 2>&1 || true
  rm -f /etc/krb5.keytab
  kadmin.local -q "ktadd -k /etc/krb5.keytab host/$GATE" >/dev/null
  pkill -x krb5kdc 2>/dev/null || true; krb5kdc

  # the gate: GSSAPI first, password fallback (as the real one allows)
  id "$LOGIN" >/dev/null 2>&1 || useradd -m -s /bin/sh "$LOGIN"
  echo "$LOGIN:$PASS" | chpasswd
  id epita >/dev/null 2>&1 || useradd -m -s /bin/sh epita
  mkdir -p "$AFS/.confs"
  echo hello >"$AFS/hello.txt"
  chown -R "$LOGIN" /afs
  mkdir -p /run/sshd
  cat >/etc/ssh/sshd_config.d/afs-lab.conf <<EOF
GSSAPIAuthentication yes
GSSAPIStrictAcceptorCheck no
PasswordAuthentication yes
KbdInteractiveAuthentication yes
UsePAM yes
EOF
  ssh-keygen -A >/dev/null
  pkill -f '^sshd: /usr/sbin/sshd' 2>/dev/null || pkill -x sshd 2>/dev/null || true
  /usr/sbin/sshd
  echo "lab ready: su - epita, then run afs (login $LOGIN, password $PASS)"
}

setup
