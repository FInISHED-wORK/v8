# V8 - Chip8 emulator in V

Almost complete Chip8 emulator written in V using gg module as a graphic interface.

## How to:

ATM the miniaudio wrapper has a bug that is not building when imported, to fix this you need to apply a path after cloning the repo.
- Issue: https://github.com/Larpon/miniaudio/issues/13


```
git clone --recursive https://github.com/marcosantos98/v8.git
cd v8
patch miniaudio/miniaudio.auto.c.v < miniaudio.patch
v8 run v8.v [rom_path] || v v8.v && ./v8 [rom_path]
```

## Working and not working:

- [x] All opcodes
- [x] Display
- [ ] Sound
- [x] Keypad
- [x] Font
- [x] Memory
- [x] Stack
- [x] Delay
- [ ] Super-Chip support
- [ ] XO-Chip support
- [ ] Quirks

## Third party ROMS provided in the repo:

- [Chip8 Test Suite by Timendus](https://github.com/Timendus/chip8-test-suite)
    - Passing all test excluding the **Quirks**
- [Tetris and Brix from dmatlack/chip8](https://github.com/dmatlack/chip8/)
    - All working with the expected bugs
- [Chip8 Test ROM by metteo](https://github.com/metteo/chip8-test-rom/)
    - OK

## Sofware used:

- [Miniaudio Wrapper by Larpron](https://github.com/Larpon/miniaudio)