#+build freestanding

package kernel
import "core:mem"

// Bare metal has no wall clock unless the embedder provides one, and Lua's
// public allocator API intentionally has no clock hook. Address entropy still
// gives each state a useful seed on machines with relocation or varied arena
// placement; on fixed-address firmware this is deterministic but fully correct.
make_seed :: proc(g: ^Global_State) -> u32 {
	buff: [3 * size_of(uintptr)]u8
	local: int
	p0 := uintptr(g)
	p1 := uintptr(&local)
	p2 := uintptr(rawptr(make_seed))
	mem.copy(&buff[0], &p0, size_of(uintptr))
	mem.copy(&buff[size_of(uintptr)], &p1, size_of(uintptr))
	mem.copy(&buff[2 * size_of(uintptr)], &p2, size_of(uintptr))
	return string_hash(&buff[0], len(buff), 0)
}
