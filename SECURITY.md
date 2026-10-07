# Security policy

## Reporting a problem in a script

If you find a security problem in one of these scripts (for example a command that could delete or expose data it
should not, unsafe handling of credentials, or a way to make a script run something it was not asked to run), please
tell us privately first:

- E-mail: **security@srvscripts.com**
- Or the contact form at <https://srvscripts.com/contact/> (put "Security" in the subject)

Please include the script name and version (the `Version:` line in its header), what you ran, and what happened.
Do not include real passwords, keys or customer data; a redacted example is enough.

We reply within 3 business days (Monday to Friday, 09:00 to 18:00 UTC). Once a fix is published we credit you in the
script's changelog unless you ask us not to.

Please do not open a public issue for a security problem until a fixed version is released.

## Supported versions

Only the latest version of each script is supported. Each script's folder has a `CHANGELOG.md`, and every release is
tagged `<script-folder>/v<version>` in this repository.

## Verifying a download

Every script has a `.sha256` file next to it, and the same checksum is shown on its page on srvScripts.com:

```bash
sha256sum -c restic-offsite-backup.sh.sha256
```

```powershell
(Get-FileHash .\Invoke-M365Offboarding.ps1 -Algorithm SHA256).Hash
```

## Scope

This policy covers the scripts in this repository. For the srvScripts.com website itself, see
<https://srvscripts.com/.well-known/security.txt>.
