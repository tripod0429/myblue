# vim: set ft=make :

# Enroll another FIDO2 hardware key for LUKS unlock (after setup-luks-fido2-unlock)
add-luks-fido2-key:
    #!/usr/bin/bash
    run0 /usr/libexec/myblue/luks-add-fido2-key.sh
