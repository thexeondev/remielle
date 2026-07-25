# Remielle
![segs](assets/segs.png)

**Remielle** is a Zenless Zone Zero server emulator that prioritizes **efficiency**, **stability** and **correctness**.

**Remielle** makes heavy use of comptime semantics in order to ensure logic correctness on the level of the type system, this eliminates most common bugs and pitfalls that occur in most implementations.

We maintain our own implementation of `Io` interface, `RemiellIo`. It's based on coroutines and supports both **Linux** and **Windows**. It utilizes high-end APIs these systems offer (Linux: **io_uring**; Windows: **I/O Completion Ports**).

We also maintain an in-house implementation of `protobuf` serializer and compiler, `rmpb`. This allows us to avoid a dependency on, for example, `protoc`. The replacement fulfilling the needs of this server is just ~600 lines of code!

## Requirements
To build **Remielle** from sources you need:
- Zig Compiler, version `0.16.0`: [Linux](https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz)/[Windows](https://ziglang.org/download/0.16.0/zig-x86_64-windows-0.16.0.zip)

For use with the game client, the client patch is required: [vortex](https://git.xeondev.com/ESD/vortex) (a replacement is being worked on)

#### Currently supported client version: `CNBetaWin3.2.0`, it can be found in our [discord server](https://discord.xeondev.com/)

## Steps to compile and run
Linux:
```sh
# git(1) must be available in the $PATH
git clone https://git.xeondev.com/remielle/remielle.git
cd remielle
. ./envrc # The `envrc` script will setup the zig compiler for you.
zig build serve-all
```
Windows (powershell):
```ps1
# git(1) must be available in the $PATH
git clone https://git.xeondev.com/remielle/remielle.git
cd remielle
./envrc.ps1 # The `envrc.ps1` script will setup the zig compiler for you.
zig build serve-all
```

## Configuration
The configuration of Remielle is done by editing `dpsv/config.zon` and `gamesv/config.zon` and (re)compiling the source code.

Some of the server behavior can be also overridden through command line options.

## Contributing
[Donate](https://boosty.to/xeondev/donate).

[Join project-specific discord server](https://remielle.xeondev.com).

[Join ReversedRooms discord server](https://discord.xeondev.com).

[Join ReversedRooms telegram channel](https://t.me/reversedrooms).

The contributions (in form of patches) can be submitted in one of our discord servers. You can also get an account on [our git instance](https://git.xeondev.com/) after a number of accepted contributions.

## License
This repository was made public in the hopes that it will be useful. However, it comes with no warranty whatsoever (expressed or implied).
It's licensed under [GNU Affero General Public License v3](LICENSE).
