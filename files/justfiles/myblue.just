# vim: set ft=make :

# Enroll another FIDO2 hardware key for LUKS unlock (after setup-luks-fido2-unlock)
add-luks-fido2-key:
    #!/usr/bin/bash
    run0 /usr/libexec/myblue/luks-add-fido2-key.sh

# Report what the plugged-in security key is used for, and what a backup key still needs (--help for options)
[positional-arguments]
@audit-security-key *args:
    exec /usr/libexec/myblue/keyaudit.sh "$@"
