module main

import os
import rand
import gg
import gx
import miniaudio

struct Chip8 {
mut:
	mem              []u8
	registers        []u8
	stack            []u16
	stack_ptr        u16
	address          u16
	pc               u16
	delay_timer      u8
	sound_timer      u8
	halted           bool
	v_key            i16
	keys             map[u8]u8
	pressed_keys     map[i16]bool
	display_buffer   [][]int
	current_inst     u16
	log_debug        bool              = true
	gg               &gg.Context       = unsafe { nil }
	miniaudio_engine &miniaudio.Engine = unsafe { nil }
}

fn main() {
	mut log_debug := false

	if os.args.len < 2 {
		println('Usage: ./v8 [path to chip8 ROM] [options]')
		println('   Options:')
		println('       -d: prints rom execution debug')
		exit(1)
	} else if os.args.len == 3 {
		if os.args[2] == '-d' {
			log_debug = true
		} else {
			println('Usage: ./v8 [path to chip8 ROM] [options]')
			println('   Options:')
			println('       -d: prints rom execution debug')
			exit(1)
		}
	}

	mut v8 := &Chip8{
		// 0 - 0x200 - Chip8 reserved
		// 0xF00 - 0xFFF - Display refresh
		// 0xEA0 - 0xEFF - Call stack
		mem: []u8{len: 4096, init: 0}
		// 16: Is the carry flag, no borrow and colliding pixel flag
		registers: []u8{len: 16, init: 0}
		// The stack is only used to store return addresses when subroutines are called.
		// The original RCA 1802 version allocated 48 bytes for up to 12 levels of nesting;
		stack: []u16{len: 48, init: 0}
		stack_ptr: 0
		address: 0
		pc: 0x200
		delay_timer: 0
		sound_timer: 0
		halted: false
		v_key: -1
		keys: map[u8]u8{}
		pressed_keys: map[i16]bool{}
		display_buffer: [][]int{len: 64, init: []int{len: 32}}
		log_debug: log_debug
		gg: 0
	}

	v8.keys[49] = 0x1 // 1
	v8.keys[50] = 0x2 // 2
	v8.keys[51] = 0x3 // 3
	v8.keys[52] = 0xc // 4
	v8.keys[65] = 0x7 // a
	v8.keys[67] = 0xb // c
	v8.keys[68] = 0x9 // d
	v8.keys[69] = 0x6 // e
	v8.keys[70] = 0xe // f
	v8.keys[81] = 0x4 // q
	v8.keys[82] = 0xd // r
	v8.keys[83] = 0x8 // s
	v8.keys[86] = 0xf // v
	v8.keys[87] = 0x5 // w
	v8.keys[88] = 0x0 // x
	v8.keys[90] = 0xa // z

	v8.load()!

	v8.gg = gg.new_context(
		width: 64 * 10
		height: 32 * 10
		bg_color: gx.red
		window_title: 'v8 [' + os.args[1] + ']'
		frame_fn: frame
		event_fn: on_event
		user_data: v8
	)

	v8.miniaudio_engine = &miniaudio.Engine{}
	result := miniaudio.engine_init(miniaudio.null, v8.miniaudio_engine)
	if result != .success {
		panic('Failed to initialize audio engine.')
	}

	v8.gg.run()

	miniaudio.engine_uninit(v8.miniaudio_engine)
}

fn frame(mut ctx Chip8) {
	// The delay timer should be decremented 60 times per second.
	// Since the window is being rendered at 60fps this should translate
	// to 60Hz rigth?
	if ctx.delay_timer > 0 {
		ctx.delay_timer--
	}

	if ctx.sound_timer > 0 {
		ctx.sound_timer--
		if miniaudio.engine_play_sound(ctx.miniaudio_engine, './beep.wav'.str, miniaudio.null) != .success {
			panic('Failed to play sound ./beep.wav')
		}
	}

	// Since this was a experiment project and I don't pretend this to
	// be a super accurate emulator, the amount of cycles per frames
	// was chossen after reading some posts about emulating the CPU speed
	// for the Chip 8
	for _ in 0 .. 14 {
		ctx.step()
	}

	ctx.gg.begin()
	for i in 0 .. 64 {
		for j in 0 .. 32 {
			if ctx.display_buffer[i][j] == 1 {
				ctx.gg.draw_rect_filled(i * 10, j * 10, 10, 10, gx.rgb(155, 188, 15))
			} else {
				ctx.gg.draw_rect_filled(i * 10, j * 10, 100, 100, gx.rgb(15, 56, 15))
			}
		}
	}
	ctx.gg.show_fps()
	ctx.gg.end()
}

fn on_event(e &gg.Event, mut ctx Chip8) {
	if e.typ == .key_down {
		if e.key_code == gg.KeyCode.escape {
			ctx.gg.quit()
		} else if e.key_code == gg.KeyCode.l {
			ctx.halted = false
		}
		if ctx.v_key != -1 && u8(e.key_code) in ctx.keys {
			ctx.registers[ctx.v_key] = ctx.keys[u8(e.key_code)]
			ctx.pressed_keys[ctx.keys[u8(e.key_code)]] = true
		} else if u8(e.key_code) in ctx.keys {
			ctx.pressed_keys[ctx.keys[u8(e.key_code)]] = true
		}
	} else if e.typ == .key_up {
		if ctx.v_key != -1 && u8(e.key_code) in ctx.keys
			&& ctx.pressed_keys[ctx.keys[u8(e.key_code)]] {
			ctx.v_key = -1
			ctx.pressed_keys[ctx.keys[u8(e.key_code)]] = false
		} else if u8(e.key_code) in ctx.keys {
			ctx.pressed_keys[ctx.keys[u8(e.key_code)]] = false
		}
	}
}

fn (mut ctx Chip8) load() !string {
	program := os.read_file(os.args[1])!

	for i in 0 .. program.len {
		ctx.mem[0x200 + i] = program[i]
	}

	// https://github.com/mattmikolay/chip-8/wiki/Mastering-CHIP%E2%80%908#drawing-fonts
	mut fonts := [][]int{len: 16, init: []int{len: 5}}
	fonts[0x0] = [0xF0, 0x90, 0x90, 0x90, 0xF0] // 0
	fonts[0x1] = [0x20, 0x60, 0x20, 0x20, 0x70] // 1
	fonts[0x2] = [0xF0, 0x10, 0xF0, 0x80, 0xF0] // 2
	fonts[0x3] = [0xF0, 0x10, 0xF0, 0x10, 0xF0] // 3
	fonts[0x4] = [0x90, 0x90, 0xF0, 0x10, 0x10] // 4
	fonts[0x5] = [0xF0, 0x80, 0xF0, 0x10, 0xF0] // 5
	fonts[0x6] = [0xF0, 0x80, 0xF0, 0x90, 0xF0] // 6
	fonts[0x7] = [0xF0, 0x10, 0x20, 0x40, 0x40] // 7
	fonts[0x8] = [0xF0, 0x90, 0xF0, 0x90, 0xF0] // 8
	fonts[0x9] = [0xF0, 0x90, 0xF0, 0x10, 0xF0] // 9
	fonts[0xA] = [0xF0, 0x90, 0xF0, 0x90, 0x90] // A
	fonts[0xB] = [0xE0, 0x90, 0xE0, 0x90, 0xE0] // B
	fonts[0xC] = [0xF0, 0x80, 0x80, 0x80, 0xF0] // C
	fonts[0xD] = [0xE0, 0x90, 0x90, 0x90, 0xE0] // D
	fonts[0xE] = [0xF0, 0x80, 0xF0, 0x80, 0xF0] // E
	fonts[0xF] = [0xF0, 0x80, 0xF0, 0x80, 0x80] // F

	for i in 0 .. fonts.len {
		for j in 0 .. fonts[i].len {
			ctx.mem[i * 5 + j] = u8(fonts[i][j])
		}
	}

	return program
}

fn (mut ctx Chip8) step() {
	if !ctx.halted && ctx.v_key == -1 {
		inst := ctx.mem[ctx.pc + 1] | u16(ctx.mem[ctx.pc]) << 8
		ctx.current_inst = inst
		nnn := u16(inst & 0x0FFF)
		nn := u8(inst & 0xFF)

		if inst < 0x1000 {
			if inst == 0x00E0 {
				// Clears the screen
				// i.e: 0x00E0
				for i in 0 .. 64 {
					for j in 0 .. 32 {
						ctx.display_buffer[i][j] = 0
					}
				}
				ctx.debug('clear screen')
				ctx.pc += 2
			} else if inst == 0x00EE {
				// Returns from a subroutine
				// i.e: 0x00EE
				ctx.debug('return to ${ctx.stack[ctx.stack_ptr]:04X}')
				ctx.stack_ptr--
				ctx.pc = ctx.stack[ctx.stack_ptr]
			} else {
				// Calls machine code routine (RCA 1802 for COSMAC VIP) at address NNN. Not necessary for most ROMs.
				// i.e: 0NNN
				ctx.debug('call machine code at ${nnn:04X}')
				ctx.pc = nnn
			}
		} else if inst >= 0x1000 && inst < 0x2000 {
			// Jumps to address NNN.
			// i.e: 1NNN
			ctx.debug('jump to ${nnn:04X}')
			ctx.pc = nnn
		} else if inst >= 0x2000 && inst < 0x3000 {
			// Calls subroutine at NNN.
			// i.e: 2NNN
			ctx.debug('call subroutine at ${nnn:04X}')
			ctx.stack[ctx.stack_ptr] = ctx.pc + 2
			ctx.stack_ptr++
			ctx.pc = nnn
		} else if inst >= 0x3000 && inst < 0x4000 {
			// Skips the next instruction if VX equals NN (usually the next instruction is a jump to skip a code block).
			// i.e: 3XNN
			index := (inst >> 8) & 0xF
			val := inst & 0xFF
			ctx.debug('Value at register ${index:02X} == ${val:02X}. Val: ${ctx.registers[index]:02X}')
			if ctx.registers[index] == val {
				ctx.pc += 4
			} else {
				ctx.pc += 2
			}
		} else if inst >= 0x4000 && inst < 0x5000 {
			// Skips the next instruction if VX does not equal NN (usually the next instruction is a jump to skip a code block).
			// i.e: 4XNN
			index := (inst >> 8) & 0xF
			val := inst & 0xFF
			ctx.debug('Value at register ${index:02X} != ${val:02X}. Val: ${ctx.registers[index]:02X}')
			if ctx.registers[index] != val {
				ctx.pc += 4
			} else {
				ctx.pc += 2
			}
		} else if inst >= 0x5000 && inst <= 0x5FF0 {
			// Skips the next instruction if VX equals VY (usually the next instruction is a jump to skip a code block).
			// i.e: 5XY0
			vx := (inst >> 8) & 0xF
			vy := (inst & 0xFF) >> 4
			ctx.debug('Val at ${vx:02X} equals val at ${vx:02X}? ${ctx.registers[vx]:02X} == ${ctx.registers[vy]:02X}')
			if ctx.registers[vx] == ctx.registers[vy] {
				ctx.pc += 4
			} else {
				ctx.pc += 2
			}
		} else if inst >= 0x6000 && inst < 0x7000 {
			// Sets VX to NN.
			// i.e: 6XNN -> VX = NN
			index := (inst >> 8) & 0xF
			ctx.registers[index] = nn
			ctx.debug('Set register ${index:X} to ${nn:04X}')
			ctx.pc += 2
		} else if inst >= 0x7000 && inst < 0x8000 {
			// Adds NN to VX (carry flag is not changed).
			// i.e: 7XNN -> VX += NN
			index := (inst >> 8) & 0xF

			ctx.registers[index] += nn
			if ctx.registers[index] > 0xFF {
				ctx.registers[index] -= 256
			}

			ctx.debug('Add ${nn:02X} to register ${index:X} Res: ${ctx.registers[index]:02X}')
			ctx.pc += 2
		} else if (inst >> 8) & 0xFF >= 0x80 && (inst >> 8) & 0xFF <= 0x8F {
			vx := (inst >> 8) & 0xF
			vy := (inst & 0xFF) >> 4
			action := (inst & 0xFF) & 0xF
			if action == 0x0 {
				// Sets VX to the value of VY.
				// i.e: 8XY0 -> VX = VY
				ctx.registers[vx] = ctx.registers[vy]
				ctx.debug('Set value of ${vx:02X} to ${ctx.registers[vy]:02X} from ${vy:02X}')
				ctx.pc += 2
			} else if action == 0x1 {
				// Sets VX to VX or VY. (bitwise OR operation)
				// i.e: 8XY1 -> VX |= VY
				ctx.registers[vx] |= ctx.registers[vy]
				ctx.debug('Set value of ${vx:02X} to ${ctx.registers[vx]:04X} from ${vx:02X} | ${vy:02X}')
				ctx.pc += 2
			} else if action == 0x2 {
				// Sets VX to VX and VY. (bitwise AND operation)
				// i.e: 8XY2 -> VX &= VY
				ctx.registers[vx] &= ctx.registers[vy]
				ctx.debug('Set value of ${vx:02X} to ${ctx.registers[vx]:04X} from ${vx:02X} & ${vy:02X}')
				ctx.pc += 2
			} else if action == 0x3 {
				// Sets VX to VX xor VY
				// i.e: 8XY3 -> VX ^= VY
				ctx.registers[vx] ^= ctx.registers[vy]
				ctx.debug('Set value of ${vx:02X} to ${ctx.registers[vx]:04X} from ${vx:02X} ^ ${vy:02X}')
				ctx.pc += 2
			} else if action == 0x4 {
				// Adds VY to VX. VF is set to 1 when there's a carry, and to 0 when there is not.
				// i.e: 8XY4 -> VX += VY

				carry := i16(ctx.registers[vx] + ctx.registers[vy]) > 0xFF

				ctx.debug('VX += VY | ${ctx.registers[vx]:02X} [${ctx.registers[vx]}] + ${ctx.registers[vy]:02X} [${ctx.registers[vy]}] = ${(
					ctx.registers[vx] + ctx.registers[vy]):02X} [${(ctx.registers[vx] +
					ctx.registers[vy])}]')
				ctx.registers[vx] += ctx.registers[vy]

				if carry {
					ctx.registers[0xF] = 1
				} else {
					ctx.registers[0xF] = 0
				}
				ctx.pc += 2
			} else if action == 0x5 {
				// VY is subtracted from VX. VF is set to 0 when there's a borrow, and 1 when there is not.
				// i.e: 8XY5 -> VX -= VY

				flag := ctx.registers[vx] >= ctx.registers[vy]

				ctx.debug('VX -= VY | ${ctx.registers[vx]:02X} [${ctx.registers[vx]}] - ${ctx.registers[vy]:02X} [${ctx.registers[vy]}] = ${(ctx.registers[vx] - ctx.registers[vy]):02X} [${(ctx.registers[vx] - ctx.registers[vy])}]')
				ctx.registers[vx] -= ctx.registers[vy]

				if flag {
					ctx.registers[0xF] = 1
				} else {
					ctx.registers[0xF] = 0
				}

				ctx.pc += 2
			} else if action == 0x6 {
				// Stores the least significant bit of VX in VF and then shifts VX to the right by 1.
				// i.e: 8XY6 -> VX >>= 1
				carry := ctx.registers[vx] & 1 > 0
				ctx.registers[vx] >>= 1
				if carry {
					ctx.registers[0xF] = 1
				} else {
					ctx.registers[0xF] = 0
				}
				ctx.debug('Store ${ctx.registers[0xF]:02X} in vF and shift VX to the right by 1')
				ctx.pc += 2
			} else if action == 0x7 {
				// Sets VX to VY minus VX. VF is set to 0 when there's a borrow, and 1 when there is not.
				// i.e: 8XY7 -> VX = VY - VX
				flag := ctx.registers[vy] >= ctx.registers[vx]

				ctx.registers[vx] = ctx.registers[vy] - ctx.registers[vx]
				ctx.debug('VX = VY - VX | ${ctx.registers[vy]:02X} [${ctx.registers[vy]}] - ${ctx.registers[vx]:02X} [${ctx.registers[vx]}] = ${(ctx.registers[vy] - ctx.registers[vx]):02X} [${(ctx.registers[vy] - ctx.registers[vx])}]')

				if flag {
					ctx.registers[0xF] = 1
				} else {
					ctx.registers[0xF] = 0
				}

				ctx.pc += 2
			} else if action == 0xE {
				// Stores the most significant bit of VX in VF and then shifts VX to the left by 1.
				// i.e: 8XYE -> VX >>= 1
				carry := ctx.registers[vx] & 0x80 > 0
				ctx.registers[vx] <<= 1
				if ctx.registers[vx] > 255 {
					ctx.registers[vx] -= 256
				}
				ctx.debug('Store ${ctx.registers[0xF]:02X} in vF and shift VX to the left by 1')

				if carry {
					ctx.registers[0xF] = 1
				} else {
					ctx.registers[0xF] = 0
				}

				ctx.pc += 2
			} else {
				ctx.debug('Inst 0x8XY not implemented!')
				exit(1)
			}
		} else if inst >= 0x9000 && inst < 0xA000 {
			// Skips the next instruction if VX does not equal VY. (Usually the next instruction is a jump to skip a code block);
			// i.e: 9XY0
			vx := (inst >> 8) & 0xF
			vy := u8((inst & 0xFF) >> 4)
			ctx.debug('Val at ${vx:02X} doesnt equal to val at ${vx:02X} ? ${ctx.registers[vx]:04X} != ${ctx.registers[vx]:04X}')
			if ctx.registers[vx] != ctx.registers[vy] {
				ctx.pc += 4
			} else {
				ctx.pc += 2
			}
		} else if inst >= 0xA000 && inst < 0xB000 {
			// Sets I to the address NNN.
			// i.e: ANNN -> I = NNN
			ctx.address = nnn
			ctx.debug('I = ${inst:04X}')
			ctx.pc += 2
		} else if inst >= 0xB000 && inst < 0xC000 {
			// Jumps to the address NNN plus V0.
			// i.e: BNNN
			ctx.debug('Jump (BNNN) to ${(ctx.registers[0] + nnn):04X}')
			ctx.pc = ctx.registers[0] + nnn
		} else if inst >= 0xC000 && inst < 0xD000 {
			// Sets VX to the result of a bitwise and operation on a random number (Typically: 0 to 255) and NN.
			// IE: CXNN
			index := (inst >> 8) & 0xF
			rand_val := rand.u8()
			ctx.registers[index] = rand_val & nn
			ctx.debug('Set register ${index:02X} with rand & NN: ${ctx.registers[index]:02X}')
			ctx.pc += 2
		} else if inst >= 0xD000 && inst < 0xE000 {
			// Draws a sprite at coordinate (VX, VY) that has a width of 8 pixels and a height of N pixels.
			// Each row of 8 pixels is read as bit-coded starting from memory location I;
			// I value does not change after the execution of this instruction.
			// As described above, VF is set to 1 if any screen pixels are flipped from set to unset when the sprite is drawn, and to 0 if that does not happen.
			// i.e: DXYN
			x := ctx.registers[(inst >> 8) & 0xF]
			y := ctx.registers[(inst & 0xFF) >> 4]
			height := (inst & 0xFF) & 0xF
			for i in 0 .. height {
				if y + i >= 32 {
					break
				}
				mut sprite := ctx.mem[ctx.address + i]
				for j in 0 .. 8 {
					if x + j >= 64 {
						break
					}
					if sprite & 0x80 > 0 {
						if ctx.display_buffer[x + j][y + i] == 1 {
							ctx.registers[0xF] = 1
							ctx.display_buffer[x + j][y + i] = 0
						} else {
							ctx.registers[0xF] = 0
							ctx.display_buffer[x + j][y + i] = 1
						}
					}
					sprite <<= 1
				}
			}
			ctx.debug('draw pixel! X: ${x:X} Y: ${y:X} N: ${height:X}')
			ctx.pc += 2
		} else if (inst >> 8) & 0xFF >= 0xE0 && (inst >> 8) & 0xFF <= 0xEF {
			vx := (inst >> 8) & 0xF
			action := inst & 0xFF
			if action == 0x9E {
				// Skips the next instruction if the key stored in VX is pressed (usually the next instruction is a jump to skip a code block).
				// i.e: EX9E
				ctx.debug('Key in ${vx:02X} is pressed: ${!ctx.pressed_keys[i16(vx)]}')
				if ctx.pressed_keys[ctx.registers[vx]] {
					ctx.pc += 4
				} else {
					ctx.pc += 2
				}
			} else if action == 0xA1 {
				// Skips the next instruction if the key stored in VX is not pressed (usually the next instruction is a jump to skip a code block).
				// i.e: EX9E
				ctx.debug('Key in ${vx:02X} is not pressed: ${!ctx.pressed_keys[i16(vx)]}')
				if !ctx.pressed_keys[ctx.registers[vx]] {
					ctx.pc += 4
				} else {
					ctx.pc += 2
				}
			}
		} else if (inst >> 8) & 0xFF >= 0xF0 && (inst >> 8) & 0xFF <= 0xFF {
			action := inst & 0xFF
			if action == 0x07 {
				// Sets VX to the value of the delay timer.
				// i.e: FX07
				vx := (inst >> 8) & 0xF
				ctx.registers[vx] = ctx.delay_timer
				ctx.debug('Save delay timer (${ctx.delay_timer:04X}) to register ${vx}')
				ctx.pc += 2
			} else if action == 0x0A {
				// A key press is awaited, and then stored in VX (blocking operation, all instruction halted until next key event).
				// i.e: FX0A
				ctx.v_key = i16(inst >> 8 & 0xF)
				ctx.debug('Register ${ctx.v_key} = get_key()')
				ctx.pc += 2
			} else if action == 0x15 {
				// Sets the delay timer to VX.
				// i.e: FX15
				vx := (inst >> 8) & 0xF
				ctx.delay_timer = ctx.registers[vx]
				ctx.debug('Set delay timer to ${ctx.delay_timer}')
				ctx.pc += 2
			} else if action == 0x18 {
				// 	Sets the sound timer to VX.
				// i.e: FX18
				vx := (inst >> 8) & 0xF
				ctx.sound_timer = ctx.registers[vx]
				ctx.debug('Set sound timer to ${ctx.registers[vx]}')
				ctx.pc += 2
			} else if action == 0x1E {
				// Adds VX to I. VF is not affected.
				// Most CHIP-8 interpreters' FX1E instructions do not affect VF, with one exception: the CHIP-8 interpreter for
				// the Commodore Amiga sets VF to 1 when there is a range overflow (I+VX>0xFFF), and to 0 when there is not.
				// The only known game that depends on this behavior is Spacefight 2091!, while at least one game, Animal Race, depends on VF not being affected.
				// i.e: FX1E
				vx := (inst >> 8) & 0xF
				ctx.address += ctx.registers[vx]
				ctx.debug('Add VX to I')
				ctx.pc += 2
			} else if action == 0x29 {
				// Sets I to the location of the sprite for the character in VX. Characters 0-F (in hexadecimal) are represented by a 4x5 font.
				// i.e: FX29
				vx := (inst >> 8) & 0xF
				ctx.address = ctx.registers[vx] * 5
				ctx.debug('set I to sprite of VX')
				ctx.pc += 2
			} else if action == 0x33 {
				// Stores the binary-coded decimal representation of VX, with the hundreds digit in memory at location in I,
				// the tens digit at location I+1, and the ones digit at location I+2.
				// i.e: FX33
				vx := (inst >> 8) & 0xF
				ctx.mem[ctx.address] = ctx.registers[vx] / 100
				ctx.mem[ctx.address + 1] = ctx.registers[vx] % 100 / 10
				ctx.mem[ctx.address + 2] = ctx.registers[vx] % 10
				ctx.debug('set_BCD(Vx) *(I+0) = BCD(3); *(I+1) = BCD(2);*(I+2) = BCD(1);')
				ctx.pc += 2
			} else if action == 0x55 {
				// Stores from V0 to VX (including VX) in memory, starting at address I.
				// The offset from I is increased by 1 for each value written, but I itself is left unmodified.
				// i.e: FX55
				vx := (inst >> 8) & 0xF
				mut i := 0
				for i <= vx {
					ctx.mem[ctx.address + i] = u8(ctx.registers[i])
					i++
				}
				ctx.debug('reg_dump(Vx, &I)')
				ctx.pc += 2
			} else if action == 0x65 {
				// Fills from V0 to VX (including VX) with values from memory, starting at address I.
				// The offset from I is increased by 1 for each value read, but I itself is left unmodified.
				// i.e: FX65
				vx := (inst >> 8) & 0xF
				mut i := 0
				for i <= vx {
					ctx.registers[i] = ctx.mem[ctx.address + i]
					i++
				}
				ctx.debug('reg_load(Vx, &I)')
				ctx.pc += 2
			}
		} else {
			ctx.debug('Not implemented yet! ${int(inst):04X}')
			exit(1)
		}
	}
}

fn (mut ctx Chip8) debug(msg string) {
	if ctx.log_debug {
		println('PC: ${ctx.pc:04X} INST: ${ctx.current_inst:04X} I: ${ctx.address:04X} vF: ${ctx.registers[0xF]:02X} Msg: ${msg}')
	}
}

// TODO(#1): Implement or remove the Chip8::halted
