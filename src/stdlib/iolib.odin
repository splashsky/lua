package stdlib

// iolib.odin -- our analogue of reference Lua's `liolib.c`.
//
// The I/O library: the file-handle userdata type and its methods (read/write/
// lines/seek/flush/setvbuf/close), the default input/output handles, and the
// convenience free functions (io.open/io.read/io.write/io.lines/io.popen/...).
// We back these with Odin's core file facilities rather than C stdio.
//
// TODO(phase-9): the file-handle userdata + methods and the io.* free functions.
