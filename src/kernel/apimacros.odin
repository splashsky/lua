package kernel
// apimacros.odin -- the handful of stack-manipulation conveniences that reference
// Lua defines as *macros* in `lua.h` (rather than functions in `lapi.c`). They are
// pure sugar over `lua_rotate`, `lua_copy`, `lua_settop`, and `lua_rawgeti`, but
// host code and the standard library reach for them constantly, so they deserve
// first-class, well-commented homes here in the public-API package.

// Remove the element at the given valid index, shifting everything above it down
// to fill the gap -- reference `lua_remove`. Implemented, exactly as the macro is,
// by rotating the element to the top and then popping it. Cannot be called with a
// pseudo-index, since those do not name a real stack slot.
api_remove :: proc(L: ^State, idx: int) {
	api_rotate(L, idx, -1)
	api_pop(L, 1)
}

// Move the top element into the given valid index, shifting everything above that
// index up to open a slot -- reference `lua_insert`. The inverse motion of
// `lua_remove`; again just a rotate.
api_insert :: proc(L: ^State, idx: int) {
	api_rotate(L, idx, 1)
}

// Move the top element into the given valid index *without* shifting (so it
// overwrites whatever was there), then pop the top -- reference `lua_replace`.
api_replace :: proc(L: ^State, idx: int) {
	api_copy(L, -1, idx)
	api_pop(L, 1)
}

// Push the global environment table onto the stack -- reference
// `lua_pushglobaltable`. The globals table lives at a fixed registry slot.
api_pushglobaltable :: proc(L: ^State) {
	api_rawgeti(L, REGISTRYINDEX, Integer(RIDX_GLOBALS))
}
