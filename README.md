[![Latest Build](https://github.com/soomtong/cyber/actions/workflows/latest-build.yml/badge.svg)](https://github.com/soomtong/cyber/actions/workflows/latest-build.yml)
[![Discord Server](https://img.shields.io/discord/828041790711136274.svg?color=7289da&label=Discord&logo=discord&style=flat-square)](https://discord.gg/YF82GYvBxQ)

<img alt="Cyber" src="https://github.com/fubark/cyber/assets/94020660/f7a568bc-5223-41e3-895b-b102d2715187" width="50%">

Cyber is a fast, efficient, and concurrent scripting language. You can embed it into your applications, games, or engines on desktop or web. Cyber also comes with a CLI so you can do scripting on your computer.

- [Homepage](https://cyberscript.dev)
- [Playground](https://cyberscript.dev/play.html)
- [Documentation](https://soomtong.github.io/cyber)
- [Downloads](https://github.com/soomtong/cyber/releases)
- [Performance](https://cyberscript.dev/performance.html)
- [Building](https://github.com/soomtong/cyber/blob/master/docs/build.md)
- [Contributing](https://github.com/soomtong/cyber/blob/master/docs/contributing.md)

### Supported Platforms
- Linux x64 (Ubuntu, Fedora, Arch)
- macOS x64
- macOS arm64
- Windows x64
- WASM Web
- WASM WASI

### Install
- Install using the command prompt (Linux, macOS)
```sh
# Install most recent release.
curl -fsSL https://raw.githubusercontent.com/soomtong/cyber/master/install.sh | bash

# Install most recent dev build.
curl -fsSL https://raw.githubusercontent.com/soomtong/cyber/master/install.sh | bash -s latest
```
  The bundle is unpacked into `/usr/local/lib/cyber` and linked as `/usr/local/bin/cyber`.
  Override the locations with `CYBER_HOME` and `CYBER_BIN`; `sudo` is used only when they are not writable.
- Install from [Downloads](https://github.com/soomtong/cyber/releases). Keep `cyber` and the bundled `src/` directory together.
- Packages
  - Arch Linux User Repository (AUR): [cyber](https://aur.archlinux.org/packages/cyber-bin), [cyber(alternative)](https://aur.archlinux.org/packages/cyberscript)
