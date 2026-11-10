# Chao TV signing key

`chaotv-release.p12` signs the Google TV APK so updates install over the
previous version (`adb install -r` needs the same signature). It is committed
on purpose: it only proves "this APK came from this repo's CI", and installing
anything on the house Google TV already requires adb access to it. Password
`chaotv-house`, alias `chaotv`.
