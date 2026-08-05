package lua

// luac_combine.odin -- the multi-chunk "combine" step used by the standalone
// `luac` compiler, our analogue of the `combine` helper in reference luac.c.
//
// `luac` can bundle several source files into a single bytecode file such that
// running the result runs every input in order. Reference Lua achieves this with
// a small trick: it compiles a wrapper chunk that is the text `(function()end)();`
// repeated once per input file, which yields a main function whose bytecode
// closes over and calls exactly N nested prototypes in sequence. It then swaps
// each of those N placeholder prototypes for the real prototype of the
// corresponding input file. Dump that wrapper and you have one chunk that, when
// executed, runs file 1, then file 2, and so on.
//
// The pointer surgery (reaching into a prototype's nested-function array and its
// upvalue descriptors) belongs in the kernel, where these structures are owned
// and understood, rather than in the CLI. So we expose exactly one helper,
// `luac_combine`, and let the CLI dump its result through the ordinary
// `lua_dump`, which serializes whatever Lua function sits on top of the stack.

// The per-file wrapper text. One copy compiles to a single "make a closure and
// call it" pair; N copies compile to N such pairs, giving us N nested prototypes
// to overwrite. Reference luac.c FUNCTION.
@(private = "file")
COMBINE_FUNCTION : string : "(function()end)();\n"

// The reader handed to `lua_load`: it returns the wrapper text once per remaining
// count and then signals end-of-input. `data` points at an `int` countdown that
// starts at N (the number of input files). Reference luac.c reader.
@(private = "file")
combine_reader :: proc "c" (L: ^State, data: rawptr, size: ^uint) -> [^]u8 {
	remaining := (^int)(data)
	if remaining^ > 0 {
		remaining^ -= 1
		size^ = uint(len(COMBINE_FUNCTION))
		return raw_data(COMBINE_FUNCTION)
	}
	size^ = 0
	return nil
}

// Combine the `n` chunk closures already sitting on the stack (bottom-most is the
// first input file) into a single wrapper closure that runs them all in order.
//
// On success the wrapper closure is left on top of the stack (above the inputs)
// and its prototype is returned; the caller typically dumps it with `lua_dump`.
// For `n == 1` there is nothing to combine: the lone chunk is already exactly
// what we want, so we simply return its prototype and leave the stack untouched.
//
// On failure (only possible for `n > 1`, if the internally generated wrapper
// somehow fails to compile) this returns `nil` and leaves the error message on
// top of the stack for the caller to report. Reference luac.c combine.
combine :: proc(L: ^State, n: int) -> ^Proto {
	if n == 1 {
		return api_closure_value(stack_value(L, L.top - 1)).p
	}
	// Compile the N-times-repeated wrapper. Reference names it "=(luac)".
	counter := n
	status := api_load(L, combine_reader, &counter, "=(luac)", "")
	if status != .Ok {
		return nil
	}
	wrapper := api_closure_value(stack_value(L, L.top - 1)).p
	// The wrapper we just pushed sits on top; the N inputs are directly beneath
	// it. Overwrite each placeholder child prototype with a real input prototype,
	// preserving input order.
	for i in 0 ..< n {
		child := api_closure_value(stack_value(L, L.top - 1 - n + i)).p
		wrapper.p[i] = child
		// A main chunk's first upvalue is _ENV. As a standalone chunk it reads
		// _ENV from a stack slot (`instack == 1`); nested under the wrapper it
		// must instead inherit the wrapper's _ENV upvalue, so clear the flag.
		if child.sizeupvalues > 0 {
			child.upvalues[0].instack = 0
		}
	}
	return wrapper
}
