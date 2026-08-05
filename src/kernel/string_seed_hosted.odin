#+build !freestanding

package kernel
import "core:mem"
import "core:time"

// Hosted states mix addresses with the wall clock, mirroring luai_makeseed's
// inexpensive per-process collision hardening.
make_seed :: proc(g: ^Global_State) -> u32 {
	buff: [3 * size_of(uintptr)]u8
	h := u32(time.now()._nsec)
	local: int
	p0 := uintptr(g)
	p1 := uintptr(&local)
	p2 := uintptr(rawptr(make_seed))
	mem.copy(&buff[0], &p0, size_of(uintptr))
	mem.copy(&buff[size_of(uintptr)], &p1, size_of(uintptr))
	mem.copy(&buff[2 * size_of(uintptr)], &p2, size_of(uintptr))
	return string_hash(&buff[0], len(buff), h)
}
