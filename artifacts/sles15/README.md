# SLES 15 / glibc 2.31 artifacts

This directory holds the **verification log** committed with the branch.
The `openvaf-r-*-linux-x86_64-glibc231.tar.gz` binary tarball is **not**
stored in git (it is ~45 MiB). Produce it locally or download the GitHub
Actions artifact `openvaf-r-linux-x86_64-glibc231`:

```bash
./scripts/build-sles15.sh
```

See [BUILD_SLES15.md](../../BUILD_SLES15.md) for the toolchain pin, commands,
and the recorded `GLIBC_*` versions (highest needed: **2.30**).
