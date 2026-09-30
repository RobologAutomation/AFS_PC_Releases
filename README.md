# AFS PC Software — releases

Signed release packages of the AFS controller (the Ubuntu mini-PC software
that drives the VEGA T2 meter). Source code lives in the private
repository; this one holds only finished packages.

Each release (GitHub Releases on this repository) carries:

| File | What it is |
| --- | --- |
| `afs-controller_<version>_amd64.deb` | the package |
| `afs-controller_<version>_amd64.deb.sig` | its signature (Ed25519, Robolog release key) |
| `manifest.json` | version, channel, SHA-256 and size of the package, minimum version it can update from |

Units install a package only when its signature checks against the
Robolog public key built into them, never while a delivery is running, and
roll back by themselves if the new version does not start healthy.

Channels: `beta` (bench unit and pilot sites) first, then `stable` (all
sites) once a release has run cleanly.

Versions: test builds are 0.x; the first site release is 1.0.0.
