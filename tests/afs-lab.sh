#!/bin/sh
# afs-lab.sh: a local stand-in for the EPITA gate, to reproduce and test `afs`
# without the CRI network. Needs root, /dev/fuse, iptables (Ubuntu/Debian).
#
#   tests/afs-lab.sh setup      KDC (realm CRI.EPITA.FR, short tickets) + sshd
#                               with GSSAPI as ssh.cri.epita.fr + fake AFS tree
#   tests/afs-lab.sh cut|heal   black-hole / restore the link to the gate
#                               (what a host suspend or a NAT timeout does)
#
# Client user: epita. EPITA login: xlogin, password: pw. Tickets live
# $LIFE (default 2 min), so "wait a day" is "wait past $LIFE".
set -eu

REALM=CRI.EPITA.FR GATE=ssh.cri.epita.fr
LOGIN=xlogin PASS=pw LIFE=${LIFE:-2m}
AFS=/afs/cri.epita.fr/user/x/xl/$LOGIN/u

setup() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    sshfs openssh-server krb5-kdc krb5-admin-server krb5-user iptables procps >/dev/null

  # the gate resolves to this machine
  sed -i "/[[:space:]]$GATE\b/d" /etc/hosts
  echo "127.0.0.1 $GATE" >>/etc/hosts

  cat >/etc/krb5.conf <<EOF
[libdefaults]
    default_realm = $REALM
    rdns = false
    dns_canonicalize_hostname = false
    ticket_lifetime = $LIFE
[realms]
    $REALM = {
        kdc = 127.0.0.1
    }
EOF
  mkdir -p /etc/krb5kdc
  cat >/etc/krb5kdc/kdc.conf <<EOF
[realms]
    $REALM = {
        max_life = $LIFE
        kdc_tcp_listen = 88
    }
EOF
  if [ ! -e /var/lib/krb5kdc/principal ]; then
    kdb5_util create -r "$REALM" -s -P masterpw >/dev/null
  fi
  kadmin.local -q "addprinc -pw $PASS -maxlife $LIFE $LOGIN" >/dev/null 2>&1 || true
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

case "${1:-}" in
  setup) setup ;;
  cut)   iptables -C INPUT -i lo -p tcp --dport 22 -j DROP 2>/dev/null \
           || iptables -I INPUT -i lo -p tcp --dport 22 -j DROP
         iptables -C INPUT -i lo -p tcp --sport 22 -j DROP 2>/dev/null \
           || iptables -I INPUT -i lo -p tcp --sport 22 -j DROP ;;
  heal)  iptables -D INPUT -i lo -p tcp --dport 22 -j DROP 2>/dev/null || true
         iptables -D INPUT -i lo -p tcp --sport 22 -j DROP 2>/dev/null || true ;;
  *)     echo "usage: $0 setup|cut|heal" >&2; exit 2 ;;
esac
