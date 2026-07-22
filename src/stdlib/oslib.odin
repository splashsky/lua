package stdlib

// oslib.odin -- our analogue of reference Lua's `loslib.c`.
//
// The OS library: time and date (os.time/os.date/os.difftime/os.clock), the
// environment and filesystem touches (os.getenv/os.remove/os.rename/os.tmpname),
// and process control (os.execute/os.exit). Backed by Odin's core libraries.
//
// Note the documented deviation: os.setlocale is a no-op / minimal shim, since
// std-lib-only Odin has no locale machinery, and locale collation falls back to
// byte order.
//
// TODO(phase-9): implement the os.* functions against Odin's core libs.
