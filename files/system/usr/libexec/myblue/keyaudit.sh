#!/usr/bin/bash
# keyaudit - overview of what a security key is used for on this machine,
# and what a backup key still needs. Run it with `ujust audit-security-key`.
#
# Plug in ONE key, run it, swap keys, run it again, compare. The reports list
# sites, key fingerprints and disk layout, so keep them private (umask 077):
#   (umask 077; ujust audit-security-key --verify --root > key-main.txt)
#   (umask 077; ujust audit-security-key --verify --root > key-backup.txt)
#   diff key-main.txt key-backup.txt
#
# Options:
#   --pin     list what is stored ON the key (passkeys, resident ssh keys).
#             Asks for the FIDO2 PIN.
#   --verify  test what the plugged-in key can actually do: sign with each
#             FIDO2 ssh key file, sign and decrypt with the OpenPGP card, and
#             (with --root) unlock each LUKS FIDO2 enrollment as a dry run.
#             Asks for touches and PINs.
#   --root    read the LUKS headers, through run0.
#
# Every PIN you type counts: a wrong PIN uses up a retry on the plugged-in
# key, so enter that key's PIN. Without options nothing asks for a PIN or a
# password. No mode changes keys, PINs, enrollments or settings. Missing
# tools skip their section; the image has them all (fido2-tools, gnupg2,
# openssh, git, cryptsetup, jq).

set -u
shopt -s nullglob
umask 077

WITH_ROOT=0 WITH_PIN=0 VERIFY=0
for arg in "$@"; do
  case $arg in
    --pin)    WITH_PIN=1 ;;
    --root)   WITH_ROOT=1 ;;
    --verify) VERIFY=1 ;;
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
  esac
done

TMPD=$(mktemp -d) || exit 1
trap 'rm -rf "$TMPD"' EXIT
ERRF=$TMPD/err
RC=0 ERR='' inf='' rps='' cs='' al='' lb='' meta=''   # filled in by capture()

if [ -t 1 ]; then B=$'\e[1m' D=$'\e[2m' Y=$'\e[33m' R=$'\e[0m'; else B='' D='' Y='' R=''; fi
CONFIRMED=() MISSING=() UNKNOWN=()
section()   { printf '\n%s== %s ==%s\n' "$B" "$1" "$R"; }
info()      { printf '  %s\n' "$*"; }
head2()     { printf '  %s%s%s\n' "$B" "$*" "$R"; }
dim()       { printf '  %s%s%s\n' "$D" "$*" "$R"; }
note()      { printf '  %s-> %s%s\n' "$Y" "$*" "$R"; }
confirmed() { CONFIRMED+=("$*"); }
missing()   { MISSING+=("$*"); }
unknown()   { UNKNOWN+=("$*"); }
have()      { command -v "$1" >/dev/null 2>&1; }
isnum()     { [[ ${1:-} =~ ^[0-9]+$ ]]; }
lines()     { local l; while IFS= read -r l; do [ -n "$l" ] && info "$l"; done <<<"$1"; }
# shown on the terminal even when the report is redirected to a file
tell()      { printf '>> %s\n' "$*" >&2; }
# capture VAR cmd...  -> stdout in VAR, exit code in RC, stderr (one line) in ERR
capture() {
  local __v=$1 __o; shift
  __o=$("$@" 2>"$ERRF"); RC=$?
  ERR=$(tr '\n' ' ' <"$ERRF" | sed 's/ *$//' | cut -c1-200)
  printf -v "$__v" '%s' "$__o"
}

# ==========================================================================
section "FIDO2  ->  passkeys/2FA, ssh *-sk keys, LUKS via systemd-cryptenroll"
devs='' FRC=0 FERR=''
have fido2-token && { capture devs fido2-token -L; FRC=$RC FERR=$ERR; }
if ! have fido2-token; then
  note "install fido2-tools (libfido2) to see this section"
elif [ "$FRC" -ne 0 ]; then
  info "UNKNOWN - could not list FIDO2 devices: ${FERR:-exit $FRC}"
elif [ -z "$devs" ]; then
  info "no FIDO2 device visible (key unplugged, or blocked by USBGuard: usbguard list-devices --blocked)"
else
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    dev=${line%%:*}
    head2 "$line"
    capture inf fido2-token -I "$dev"
    if [ "$RC" -ne 0 ]; then
      info "UNKNOWN - could not read the key's info: ${ERR:-exit $RC} (permissions / udev rules?)"
    else
      opts=$(sed -n 's/^options: //p' <<<"$inf")
      tries=$(sed -n 's/^pin retries: //p' <<<"$inf")
      info "options: ${opts:-?}"
      if grep -qw clientPin <<<"$opts"; then
        info "FIDO2 PIN: set, ${tries:-?} tries left (8 is the usual maximum)"
      elif grep -qw noclientPin <<<"$opts"; then
        note "no FIDO2 PIN set yet - sites that need one will ask you to create it"
      fi
      if grep -qw alwaysUv <<<"$opts"; then
        note "alwaysUv is on: this key wants the PIN on EVERY FIDO use, whatever the site asks for"
      else
        info "asks for the PIN only when the site/tool requests it; otherwise a touch is enough"
      fi
      if isnum "$tries" && [ "$tries" -lt 8 ]; then
        note "$tries PIN tries left - at 0 the FIDO2 app must be reset, which wipes every FIDO credential"
      fi
    fi

    if [ "$WITH_PIN" = 1 ]; then
      tell "FIDO2: enter the PIN of the plugged-in key to list what's stored on it"
      capture rps fido2-token -L -r "$dev"
      if [ "$RC" -ne 0 ]; then
        info "UNKNOWN - listing failed: ${ERR:-exit $RC}"
      elif [ -z "$rps" ]; then
        info "stored on the key: nothing (the listing worked and found no discoverable credentials)"
      else
        info "sites/services with credentials stored on the key:"
        lines "$(awk '{print "  - " $NF}' <<<"$rps")"
        grep -q ' ssh:' <<<"$rps" && note "resident ssh key(s): 'ssh-keygen -K' recreates the key files on a new machine"
        dim "accounts per site: fido2-token -L -k <site> $dev  (asks the PIN again)"
      fi
    fi
    dim "not listable from the key: most 2FA logins, LUKS and non-resident *-sk ssh keys (they live on the site / disk / in ~/.ssh)"
  done <<<"$devs"
fi

NKEYS=$(grep -c . <<<"$devs")
if [ "$NKEYS" -gt 1 ]; then
  note "$NKEYS keys plugged in: gpg reports only one card and test results can't be tied to one key. Unplug all but one."
  if [ "$VERIFY" = 1 ]; then
    VERIFY=0
    note "--verify switched off for this run"
    unknown "Nothing was verified: several keys were plugged in"
  fi
fi

# ==========================================================================
KL='' KLRC=0 KLERR=''
in_keyring() { [ -n "$1" ] && grep -q "^fpr:::::::::$1:" <<<"$KL"; }
# certonly FPR  -> true if the key FPR in your keyring can certify but not
# sign data: a primary key on a certify card sits in the Signature slot.
certonly() {
  [ -n "$1" ] && awk -F: -v f="$1" '$1 ~ /^(sec|ssb)$/ { c = $12; next }
    $1 == "fpr" && $10 == f { print (c ~ /c/ && c !~ /s/) ? "y" : "n"; exit }' <<<"$KL" | grep -qx y
}
# sigfprs KEY  -> fingerprints of the usable signing key and subkeys of KEY
sigfprs() {
  gpg --list-keys --with-colons -- "$1" 2>/dev/null | awk -F: '
    $1 == "pub" || $1 == "sub" { s = ($2 !~ /^[eridn]$/ && $12 ~ /s/); next }
    $1 == "fpr" && s { print $10; s = 0 }'
}

section "OpenPGP card  ->  gpg (sign, decrypt, certify); git or ssh only if set up to use it"
CARD_SN='' SIGFPR='' ENCFPR='' AUTFPR='' CARD_SIGNS=0
if ! have gpg; then
  note "gnupg not installed - skipping"
else
  capture cs gpg --card-status; CSERR=$ERR
  # After --card-status: it adds the stubs for a card gpg hasn't seen yet.
  capture KL gpg -K --with-colons; KLRC=$RC KLERR=$ERR
  if grep -q '^Application ID' <<<"$cs"; then
    lines "$(grep -E '^(Manufacturer|Serial number|Signature PIN|PIN retry counter|Signature counter|Signature key|Encryption key|Authentication key)' <<<"$cs" |
      awk -F: '{lab=$1; sub(/[ .]+$/,"",lab); val=substr($0,length($1)+2); sub(/^ +/,"",val); printf "%-20s %s\n", lab":", val}')"
    CARD_SN=$(sed -nE 's/^Serial number[ .]*: *//p' <<<"$cs")
    slotfpr() { sed -nE "s/^$1[ .]*: *//p" <<<"$cs" | tr -d ' ' | grep -E '^[0-9A-F]{40,64}$'; }
    SIGFPR=$(slotfpr 'Signature key') ENCFPR=$(slotfpr 'Encryption key') AUTFPR=$(slotfpr 'Authentication key')

    case $(sed -nE 's/^Signature PIN[ .]*: *//p' <<<"$cs") in
      "not forced") note "after the first PIN entry the card stays unlocked until you unplug it (and gpg-agent caches too) - that's why gpg usually asks only once" ;;
      forced)       note "signature PIN is forced: every signature asks for the PIN (decrypt/ssh still only once per plug-in)" ;;
    esac
    read -r pu _ pa <<<"$(sed -nE 's/^PIN retry counter[ .]*: *//p' <<<"$cs")"
    isnum "${pu:-}" && [ "$pu" -lt 3 ] && note "User PIN: only $pu tries left (unblock with the Admin PIN: gpg --card-edit, admin, passwd)"
    isnum "${pa:-}" && [ "$pa" -lt 3 ] && note "Admin PIN: only $pa tries left - at 0 the OpenPGP app has to be factory-reset"

    if [ -z "$SIGFPR$ENCFPR$AUTFPR" ]; then
      info "no keys on this card's OpenPGP app"
    else
      for s in "sign:$SIGFPR" "encrypt:$ENCFPR" "auth:$AUTFPR"; do
        f=${s#*:}; [ -z "$f" ] && continue
        if certonly "$f"; then info "${s%%:*} slot: your primary key, certify only - this is a certify card"
        elif in_keyring "$f"; then info "${s%%:*} slot: matches a key in your keyring"
        else info "${s%%:*} slot: NOT in your keyring - gpg can't use it until you import its public key"; fi
      done
      dim "the same fingerprint on two cards = the same key on both"
    fi

    if [ "$VERIFY" = 1 ]; then
      if certonly "$SIGFPR"; then
        unknown "OpenPGP card $CARD_SN: certifying not tested (it changes a key) - try it on a throwaway copy of your keyring: GNUPGHOME=\$(mktemp -d), import your public key, gpg --card-status, extend a subkey's expiry"
      elif in_keyring "$SIGFPR"; then
        tell "OpenPGP: test signature with the card - enter the User PIN if asked"
        if printf 'keyaudit\n' | gpg --yes --local-user "$SIGFPR!" --output /dev/null --sign >/dev/null; then
          info "VERIFIED: the card signs"; CARD_SIGNS=1
          confirmed "OpenPGP card $CARD_SN: signing works"
        else
          info "FAILED: signing with the card did not work (gpg's message is on the terminal)"
          missing "OpenPGP card $CARD_SN: signing test failed"
        fi
      fi
      if in_keyring "$ENCFPR"; then
        if printf 'keyaudit\n' | gpg --batch --yes --trust-model always --recipient "$ENCFPR!" --output "$TMPD/t.gpg" --encrypt 2>/dev/null; then
          tell "OpenPGP: test decryption with the card - enter the User PIN if asked"
          if gpg --yes --output /dev/null --decrypt "$TMPD/t.gpg" >/dev/null; then
            info "VERIFIED: the card decrypts"
            confirmed "OpenPGP card $CARD_SN: decryption works"
          else
            info "FAILED: decrypting with the card did not work"
            missing "OpenPGP card $CARD_SN: decryption test failed"
          fi
        else
          info "UNKNOWN - could not encrypt a test message to the card's key"
        fi
      fi
      [ -n "$AUTFPR" ] && unknown "OpenPGP auth (ssh) key: only an actual login proves it, e.g. ssh -T git@github.com"
    fi
  else
    info "no OpenPGP card found"
    [ -n "$CSERR" ] && dim "$CSERR"
  fi
fi

# ==========================================================================
section "GPG secret keys  ->  where each one is stored"
if have gpg; then
  if [ "$KLRC" -ne 0 ]; then
    info "UNKNOWN - gpg -K failed: ${KLERR:-exit $KLRC}"
  elif [ -z "$KL" ]; then
    info "no secret keys in your keyring"
  else
    awk -F: -v cs="$CARD_SN" '
      function where(sn,  r) {
        if (sn == "#") return "stub only - the secret is not on this computer"
        if (sn == "" || sn == "+") return "secret stored on this computer'"'"'s disk"
        r = "on card " sn
        if (cs != "" && index(toupper(sn), toupper(cs))) r = r "  <- the card plugged in now"
        return r
      }
      function use(c,  u) {
        if (c ~ /c/) u = u "certify "
        if (c ~ /s/) u = u "sign "
        if (c ~ /e/) u = u "encrypt "
        if (c ~ /a/) u = u "auth/ssh "
        sub(/ $/, "", u); return u
      }
      function state(v) { return v == "r" ? " (revoked)" : v == "e" ? " (expired)" : "" }
      $1 == "sec" { pend = 1; secl = sprintf("  primary %s [%s]%s  %s", $5, use($12), state($2), where($15)); next }
      $1 == "uid" && pend { printf "  %s\n%s\n", $10, secl; pend = 0; next }
      $1 == "ssb" { printf "    subkey %s [%s]%s  %s\n", $5, use($12), state($2), where($15) }
    ' <<<"$KL"

    oncard=$(awk -F: '($1=="sec"||$1=="ssb") && $15!="" && $15!="#" && $15!="+"' <<<"$KL" | grep -c .)
    stub=$(awk -F: '$1=="sec" && $15=="#"' <<<"$KL" | grep -c .)
    primcard=$(awk -F: '$1=="sec" && $15!="" && $15!="#" && $15!="+"' <<<"$KL" | grep -c .)

    if [ "$primcard" -gt 0 ]; then
      unknown "GPG: a primary key lives on a card. Whether a backup was exported before it went onto the card can't be seen from here; without one, losing that card means you can't renew or add subkeys - a new key."
    elif [ "$oncard" -gt 0 ] && [ "$stub" -gt 0 ]; then
      unknown "GPG: the primary key is a stub here. If you have an offline backup, test it in a throwaway GNUPGHOME (gpg --import, then gpg -K must show the subkeys without '>' or '#'). Only that backup lets you put the SAME subkeys on the backup card (keytocard)."
    elif [ "$oncard" -gt 0 ]; then
      unknown "GPG: the primary key's secret is on this disk - keep an offline copy. It can also add subkeys on the backup card (gpg --edit-key <id>, addcardkey): fine for signing/ssh, but only identical encryption subkeys let both cards decrypt the same messages."
    fi
  fi
fi

# ==========================================================================
section "SSH"
sock=${SSH_AUTH_SOCK:-}
gsock=$(have gpgconf && gpgconf --list-dirs agent-ssh-socket 2>/dev/null)
if [ -z "$sock" ]; then
  info "agent: none (SSH_AUTH_SOCK is not set)"
elif [ "$sock" = "$gsock" ]; then
  info "agent: gpg-agent (offers the card's authentication key as an ssh key)"
else
  info "agent: $sock"
fi
if [ -n "$sock" ] && have ssh-add; then
  capture al ssh-add -L
  case $RC in
    0) info "keys offered by the agent:"
       while read -r t _ c; do
         case $t in
           sk-*) k="FIDO2 key" ;;
           *) if [[ ${c:-} == cardno:* ]]; then k="OpenPGP card"; else k="ordinary key file"; fi ;;
         esac
         info "$(printf '  %-34s %-26s -> %s' "$t" "${c:-}" "$k")"
       done <<<"$al" ;;
    1) info "agent is running but holds no keys" ;;
    *) info "UNKNOWN - could not talk to the agent: ${ERR:-exit $RC}" ;;
  esac
fi

sk=0 skok=0 OKFILES=' '
# Signs a file, not a pipe: with stdin not a terminal, ssh-keygen asks for
# the PIN through ssh-askpass, which isn't installed, and the test fails.
printf 'keyaudit\n' >"$TMPD/msg"
info "FIDO2 ssh key files in ~/.ssh:"
for pub in "$HOME"/.ssh/*.pub; do
  t='' c=''
  read -r t _ c <"$pub" || true
  [[ $t == sk-* ]] || continue
  sk=$((sk + 1))
  priv=${pub%.pub} name=$(basename "${pub%.pub}")
  if [ ! -f "$priv" ]; then
    info "  $name  $t ${c:+($c)}  - public half only; usable only if resident (ssh-keygen -K)"
    continue
  fi
  if [ "$VERIFY" = 1 ] && have ssh-keygen; then
    tell "SSH: testing $name - touch the key if it blinks, enter its PIN if asked"
    rm -f "$TMPD/msg.sig"
    if ssh-keygen -Y sign -f "$priv" -n keyaudit@local "$TMPD/msg" >/dev/null; then
      st="VERIFIED: works with the key plugged in now"; skok=$((skok + 1)); OKFILES+="$name "
    else
      st="does NOT work with the key plugged in now (another key's, or that key was reset)"
    fi
  else
    st="found locally, not tested (use --verify)"
  fi
  info "  $name  $t ${c:+($c)}  - $st"
done
[ "$sk" -eq 0 ] && info "  none"
if [ "$sk" -gt 0 ]; then
  dim "a non-resident sk key needs this file AND its physical key - back up the file too"
  if [ "$VERIFY" = 1 ]; then
    if [ "$skok" -gt 0 ]; then
      confirmed "SSH: key file(s) that work with this key:${OKFILES% }"
    else
      missing "SSH: no FIDO2 ssh key file here works with this key. With only this key plugged in: ssh-keygen -t ed25519-sk -O resident -O verify-required -f ~/.ssh/id_ed25519_sk_<name>, then add the .pub to your servers and GitHub."
    fi
    unknown "SSH: whether servers/GitHub accept a key is only proven by logging in (ssh -i ~/.ssh/<file> -T git@github.com)"
  else
    unknown "SSH: $sk FIDO2 ssh key file(s); which physical key each belongs to is untested - rerun with --verify"
  fi
fi

if [ -f "$HOME/.ssh/config" ]; then
  idf=$(grep -iE '^[[:space:]]*IdentityFile' "$HOME/.ssh/config" | sed 's/^[[:space:]]*/  /')
  [ -n "$idf" ] && { info "IdentityFile lines in ~/.ssh/config:"; lines "$idf"; }
fi
if [ -f "$HOME/.ssh/authorized_keys" ]; then
  n=$(grep -cE '(^|[ ,])sk-' "$HOME/.ssh/authorized_keys")
  info "this machine's authorized_keys: $n FIDO2 key(s)"
  grep -q 'verify-required' "$HOME/.ssh/authorized_keys" && info "  some entries say verify-required (this machine demands the PIN)"
fi

# ==========================================================================
section "Git commit signing"
if have git; then
  cfg=$(git config --show-origin --get-regexp '^(gpg\.|user\.signingkey$|commit\.gpgsign$|tag\.gpgsign$)' 2>/dev/null)
  if [ -z "$cfg" ]; then
    info "no signing configured"
  else
    lines "$(sed -e 's/^file://' -e "s|^$HOME|~|" <<<"$cfg" | tr '\t' ' ')"
    fmt=$(git config --get gpg.format || echo openpgp)
    key=$(git config --get user.signingkey)
    case $fmt in
      ssh)
        k=${key/#\~/$HOME} t=''
        if [[ $k == key::* ]]; then
          t=${k#key::}; t=${t%% *}
        elif [ -f "$k" ]; then
          pf=$k
          [[ $pf != *.pub && -f "$k.pub" ]] && pf="$k.pub"
          read -r t _ <"$pf" || true
        fi
        case $t in
          sk-*)
            info "-> signs with a FIDO2 ssh key (touch; PIN if it was made with verify-required)"
            kn=$(basename "${k%.pub}")
            if [ "$VERIFY" = 1 ] && [ -f "$k" ]; then
              if [[ $OKFILES == *" $kn "* ]]; then confirmed "Git: commits can be signed with this key ($kn)"
              else info "-> the configured signing key ($kn) does not work with the key plugged in now"; fi
            fi
            unknown "Git: each physical key's ssh .pub must be registered on GitHub/GitLab as a *signing* key - not checkable from here" ;;
          '') info "-> ssh signing with ${key:-the first key in your ssh-agent}" ;;
          *)  info "-> signs with an ordinary ssh key ($t), or one gpg-agent serves from the card" ;;
        esac ;;
      openpgp)
        info "-> signs with GPG key ${key:-<your default key>} - see the OpenPGP sections"
        if [ -n "$SIGFPR" ] && have gpg; then
          gk=${key:-$(git config --get user.email)}
          if grep -qixF -- "$SIGFPR" <<<"$(sigfprs "${gk%!}")"; then
            info "-> its signing key is on the card plugged in now"
            [ "$CARD_SIGNS" = 1 ] && confirmed "Git: commits can be signed with this key (GPG)"
          else
            info "-> its signing key is not on the card plugged in now"
          fi
        fi ;;
      x509)    info "-> signs with X.509 (gpgsm / PIV)" ;;
    esac
  fi
else
  dim "git not installed"
fi

# ==========================================================================
# askeys FILE  -> "type base64" of each key an allowed_signers file lets sign
# commits: entries with no namespaces= option, or one that lists git.
askeys() {
  awk '
    /^[[:space:]]*(#|$)/ { next }
    {
      for (i = 2; i < NF; i++) if ($i ~ /^(ssh-|sk-|ecdsa-)/) break
      if (i >= NF) next
      opts = ""; for (j = 2; j < i; j++) opts = opts " " $j
      if (opts ~ /namespaces="/ && opts !~ /namespaces="([^"]*,)?git(,[^"]*)?"/) next
      print $i, $(i + 1)
    }' "$1"
}
# aslisted KEYS  -> says for each FIDO2 ssh key file in ~/.ssh whether it is
# in KEYS (askeys output). Sets ASN (how many are) and ASOK (those that also
# worked with the key plugged in now, in the SSH section).
aslisted() {
  ASN=0 ASOK=''
  local pub t b name
  for pub in "$HOME"/.ssh/*.pub; do
    t='' b=''
    read -r t b _ <"$pub" || true
    [[ $t == sk-* ]] || continue
    name=$(basename "${pub%.pub}")
    if grep -qxF "$t $b" <<<"$1"; then
      info "  $name: listed"; ASN=$((ASN + 1))
      [[ $OKFILES == *" $name "* ]] && ASOK+=" $name"
    else
      info "  $name: not listed"
    fi
  done
}

# verify-provenance.sh installs an image only if its commit is signed by a
# key in this file. Only the installed image's copy counts.
AS=/usr/share/myblue/allowed_signers
section "myblue updates  ->  commits signed by a key in $AS"
if [ ! -r "$AS" ]; then
  dim "$AS not found - skipping"
else
  keys=$(askeys "$AS")
  nas=$(grep -c . <<<"$keys")
  info "$nas key(s) can sign commits this machine installs images from"
  aslisted "$keys"
  dim "a key added in the repo counts once the image with it is installed"
  [ "$nas" -eq 1 ] && missing "myblue updates: only one key in allowed_signers - lose it and updates stop. Add the backup key: myblue README, \"Another signing key\""
  if [ "$VERIFY" = 1 ]; then
    if [ -n "$ASOK" ]; then confirmed "myblue updates: this key signs commits your machine installs:$ASOK"
    else missing "myblue updates: this key can't sign commits your machine installs - no key file that works with it is in allowed_signers. Add it: myblue README, \"Another signing key\""; fi
  elif [ "$ASN" -gt 0 ]; then
    unknown "myblue updates: $ASN listed key file(s); which physical key each belongs to is untested - rerun with --verify"
  fi
fi

# ==========================================================================
# chezmoi update runs `git pull --verify-signatures` (the dotfiles'
# .chezmoi.toml.tmpl). git then accepts a commit signed by an ssh key in
# gpg.ssh.allowedSignersFile, or by a GPG key gpg trusts at least
# marginally, unless gpg.minTrustLevel asks for more, or chezmoi runs git
# with gpg.openpgp.program=false, as these dotfiles do: then GPG signatures
# don't count at all. GPG keys get no count check: one key's subkeys can be
# on two cards, and gpg remembers only one of them. Run this on each card.
CZ=${XDG_CONFIG_HOME:-$HOME/.config}/chezmoi/chezmoi.toml
# git's settings as chezmoi update sees them, in the dotfiles source; not
# those of whatever repo this runs from.
CZSRC=$HOME/.local/share/chezmoi
[[ -d $CZSRC/.git ]] || CZSRC=$HOME
section "Dotfiles updates  ->  commits signed by a key in allowed_signers (or a GPG key you trust)"
if ! grep -q -- '--verify-signatures' "$CZ" 2>/dev/null; then
  info "chezmoi update doesn't check signatures (no --verify-signatures in $CZ)"
elif ! have git; then
  note "git not installed - skipping"
else
  nds=0 dsok='' nk=0 cardok=0
  das=$(git -C "$CZSRC" config --type=path --get gpg.ssh.allowedSignersFile 2>/dev/null)
  if [ -z "$das" ]; then
    info "no gpg.ssh.allowedSignersFile in git's config: only GPG signatures count"
  elif [ ! -r "$das" ]; then
    info "UNKNOWN - gpg.ssh.allowedSignersFile is $das, which can't be read"
  else
    keys=$(askeys "$das")
    nds=$(grep -c . <<<"$keys")
    info "$nds ssh key(s) in $das can sign commits chezmoi update accepts"
    aslisted "$keys"
    dsok=$ASOK
    if [ "$VERIFY" = 0 ] && [ "$ASN" -gt 0 ]; then
      unknown "Dotfiles updates: $ASN listed key file(s); which physical key each belongs to is untested - rerun with --verify"
    fi
  fi

  if grep -qF 'gpg.openpgp.program=false' "$CZ"; then
    info "GPG signatures don't count: chezmoi update runs git with OpenPGP verification off"
  elif ! have gpg; then
    dim "gnupg not installed - GPG signatures not checked"
  else
    case $(git -C "$CZSRC" config --get gpg.minTrustLevel 2>/dev/null) in
      undefined) tl='[-qnmfu]' ;;
      never)     tl='[nmfu]' ;;
      fully)     tl='[fu]' ;;
      ultimate)  tl='u' ;;
      *)         tl='[mfu]' ;;
    esac
    gk=$(gpg --list-keys --with-colons 2>/dev/null | awk -F: -v tl="^$tl\$" '
      function flush() { if (ok) print "K", pf, uid; ok = 0 }
      $1 == "pub" { flush(); ok = ($2 ~ tl && $12 ~ /S/); s = ($12 ~ /s/); t = "pub"; pf = ""; uid = ""; next }
      $1 == "sub" { s = ($2 !~ /^[eridn]$/ && $12 ~ /s/); t = "sub"; next }
      $1 == "fpr" { if (t == "pub") pf = $10; if (ok && s) print "S", $10; t = ""; s = 0; next }
      $1 == "uid" && uid == "" && $2 !~ /^[er]$/ { uid = $10 }
      END { flush() }')
    nk=$(grep -c '^K ' <<<"$gk")
    if [ "$nk" -eq 0 ]; then
      info "no GPG key here is trusted to sign them"
    else
      info "$nk GPG key(s) can sign commits chezmoi update accepts:"
      lines "$(awk '$1 == "K" { f = $2; $1 = $2 = ""; sub(/^ +/, ""); print "  " $0 "  " f }' <<<"$gk")"
      if [ -n "$SIGFPR" ] && grep -qxF "S $SIGFPR" <<<"$gk"; then
        info "-> the card plugged in now holds one of their signing keys"
        if [ "$CARD_SIGNS" = 1 ]; then cardok=1
        elif [ "$VERIFY" = 0 ]; then unknown "Dotfiles updates: this key's card holds a trusted GPG signing key; signing untested - rerun with --verify"; fi
      elif [ -n "$CARD_SN" ]; then
        info "-> the card plugged in now holds none of their signing keys"
      fi
    fi
  fi

  if [ "$nds" -eq 0 ] && [ "$nk" -eq 0 ]; then
    missing "Dotfiles updates: no key here is accepted for them, so chezmoi update refuses every commit (the dotfiles set gpg.ssh.allowedSignersFile)"
  elif [ "$nds" -eq 1 ] && [ "$nk" -eq 0 ]; then
    missing "Dotfiles updates: only one key in allowed_signers - lose it and chezmoi update refuses everything. Add another: dotfiles README, \"Adding or replacing a key\""
  fi
  if [ "$VERIFY" = 1 ] && [ $((nds + nk)) -gt 0 ]; then
    by=$dsok; [ "$cardok" = 1 ] && by+=" OpenPGP card $CARD_SN"
    if [ -n "$by" ]; then
      confirmed "Dotfiles updates: this key signs commits chezmoi update accepts:$by"
    else
      missing "Dotfiles updates: this key can't sign commits chezmoi update accepts - no key file that works with it is in allowed_signers, and its OpenPGP card holds no trusted signing key. Add its ssh keys: dotfiles README, \"Adding or replacing a key\""
    fi
  fi
fi

# ==========================================================================
section "LUKS disk encryption"
if have lsblk; then
  capture lb lsblk -lnpo NAME,FSTYPE,UUID
  luks=$(awk '$2=="crypto_LUKS"{print $1}' <<<"$lb")
  # The root disk, found the same way as luks-add-fido2-key.sh.
  rootuuid=$(xargs -n1 -a /proc/cmdline | sed -n 's/^rd\.luks\.uuid=luks-//p')
  rootdev=$(awk -v u="$rootuuid" 'u != "" && $2=="crypto_LUKS" && $3==u {print $1}' <<<"$lb")
  [ "$RC" -ne 0 ] && info "UNKNOWN - lsblk failed: ${ERR:-exit $RC}"
  [ "$RC" -eq 0 ] && [ -z "$luks" ] && info "no LUKS volumes found"
  if [ -r /etc/crypttab ]; then
    ct=$(grep -vE '^[[:space:]]*(#|$)' /etc/crypttab)
    if [ -n "$ct" ]; then
      info "/etc/crypttab:"
      lines "$(sed 's/^/  /' <<<"$ct")"
      grep -q 'fido2-device' <<<"$ct" && info "-> 'fido2-device=' means that volume unlocks with a FIDO2 key at boot"
    fi
  fi
  for dev in $luks; do
    head2 "$dev"
    if [ "$dev" = "$rootdev" ]; then add="ujust add-luks-fido2-key"
    else add="run0 systemd-cryptenroll --fido2-device=auto $dev"; fi
    if [ "$WITH_ROOT" != 1 ]; then
      dim "rerun with --root to read its header"
      unknown "LUKS $dev: header not read (rerun with --root, plus --verify to test unlocking)"
      continue
    fi
    if ! have cryptsetup || ! have jq; then
      info "UNKNOWN - needs cryptsetup and jq to read the header"
      unknown "LUKS $dev: header not read (install cryptsetup and jq)"
      continue
    fi
    capture meta run0 cryptsetup luksDump --dump-json-metadata "$dev"
    if [ "$RC" -ne 0 ] || ! jq -e . >/dev/null 2>&1 <<<"$meta"; then
      info "UNKNOWN - could not read the LUKS2 metadata (LUKS1 volume or old cryptsetup?): ${ERR:-exit $RC}"
      unknown "LUKS $dev: header could not be read"
      continue
    fi
    dim "what's enrolled in the header (enrolled is not the same as tested):"
    lines "$(jq -r '
      def yn: if . == null then "?" elif . then "yes" else "no" end;
      (.tokens // {}) | to_entries[] |
      "  token \(.key): \(.value.type) -> keyslot \((.value.keyslots // []) | join(","))" +
      (if .value.type == "systemd-fido2" then
         "   (PIN: \(.value["fido2-clientPin-required"] | yn), touch: \(.value["fido2-up-required"] | yn), UV: \(.value["fido2-uv-required"] | yn))"
       else "" end)' <<<"$meta")"
    unbound=$(jq -r '[(.tokens // {})[] | (.keyslots // [])[]] as $u | (.keyslots // {}) | keys - $u | .[]' <<<"$meta" | tr '\n' ' ' | sed 's/ $//')
    [ -n "$unbound" ] && info "  keyslot(s) without a token: $unbound - usually a passphrase (or an enrollment configured only in /etc/crypttab)"
    fids=$(jq -r '(.tokens // {}) | to_entries[] | select(.value.type == "systemd-fido2") | .key' <<<"$meta")
    nfido=$(grep -c . <<<"$fids")
    nrec=$(jq '[(.tokens // {})[] | select(.type == "systemd-recovery")] | length' <<<"$meta")

    if [ "$VERIFY" = 1 ] && [ "$nfido" -gt 0 ]; then
      unlocked=0
      for tid in $fids; do
        tell "LUKS: dry-run unlock of $dev with token $tid - enter the plugged-in key's FIDO2 PIN and touch it if asked (nothing gets opened)"
        if run0 cryptsetup open --test-passphrase --token-only --token-id "$tid" "$dev" >/dev/null; then
          info "  token $tid: VERIFIED - the key plugged in now unlocks it"; unlocked=$((unlocked + 1))
        else
          info "  token $tid: does NOT unlock with the key plugged in now (another key's enrollment, or cryptsetup's systemd FIDO2 plugin is missing)"
        fi
      done
      if [ "$unlocked" -gt 0 ]; then
        confirmed "LUKS $dev: this key unlocks it (dry run passed)"
        [ "$nfido" -eq 1 ] && missing "LUKS $dev: this key is the only FIDO2 enrollment. Plug in only the other key: $add"
      else
        missing "LUKS $dev: no FIDO2 enrollment unlocks with this key. With only this key plugged in: $add"
      fi
    elif [ "$nfido" -gt 0 ]; then
      unknown "LUKS $dev: $nfido FIDO2 enrollment(s); which keys they belong to is untested - rerun with --verify --root"
      [ "$nfido" -eq 1 ] && missing "LUKS $dev: only one FIDO2 enrollment, so at most one of your keys can unlock it"
    fi

    if [ -z "$unbound" ] && [ "$nrec" -eq 0 ]; then
      missing "LUKS $dev: no passphrase-like keyslot and no recovery key - if the keys are lost or reset, the data is gone. Add one: run0 systemd-cryptenroll --recovery-key $dev"
    elif [ -n "$unbound" ]; then
      unknown "LUKS $dev: check you still know the passphrase: run0 cryptsetup open --test-passphrase --key-slot ${unbound%% *} $dev"
    fi
  done
else
  dim "lsblk not available - skipping"
fi

# ==========================================================================
section "Backup readiness  (for the key plugged in now)"
unknown "Websites / 2FA: not visible from here. In each site's security settings, check that BOTH keys are registered."
show() {
  local label=$1 i; shift
  [ "$#" -eq 0 ] && return
  printf '  %s%s%s\n' "$B" "$label" "$R"
  for i in "$@"; do printf '    - %s\n' "$i"; done
}
show "CONFIRMED (tested in this run)" ${CONFIRMED[@]+"${CONFIRMED[@]}"}
show "MISSING" ${MISSING[@]+"${MISSING[@]}"}
show "UNKNOWN (not verified)" ${UNKNOWN[@]+"${UNKNOWN[@]}"}
[ "$VERIFY" = 0 ] && dim "nothing is CONFIRMED without --verify"

exit 0
