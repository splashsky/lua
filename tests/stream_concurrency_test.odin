package tests

import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import kernel "lang:kernel"
import stream "lang:stream"

Stream_Error_Test :: struct {
	barrier: sync.Barrier,
	isolated: bool,
}

@(test)
stream_errors_are_thread_local :: proc(t: ^testing.T) {
	state: Stream_Error_Test
	sync.barrier_init(&state.barrier, 2)
	a := thread.create(proc(th: ^thread.Thread) {
		state := (^Stream_Error_Test)(th.data)
		_ = stream.open("", "invalid")
		sync.barrier_wait(&state.barrier)
		sync.barrier_wait(&state.barrier)
		state.isolated = stream.last_error() == os.Error(os.General_Error.Invalid_Path)
	})
	b := thread.create(proc(th: ^thread.Thread) {
		state := (^Stream_Error_Test)(th.data)
		sync.barrier_wait(&state.barrier)
		stream.clear_error()
		sync.barrier_wait(&state.barrier)
	})
	a.data, b.data = &state, &state
	thread.start(a)
	thread.start(b)
	thread.destroy(a)
	thread.destroy(b)
	testing.expect(t, state.isolated, "another thread must not clear this thread's stream error")
}

Stream_Worker :: struct {
	barrier: ^sync.Barrier,
	shared:  ^stream.Stream,
	ok:      bool,
}

stream_test_reopen :: proc() -> bool {
	temp, err := os.create_temp_file("", "lang-reopen-*")
	if err != nil do return false
	path := strings.clone(os.name(temp))
	os.close(temp)
	defer delete(path)
	defer os.remove(path)
	f := stream.open(path, "wb")
	if f == nil do return false
	ok := stream.write(f, transmute([]u8)string("reopen")) == 6
	reopened := stream.reopen(path, "rb", f)
	if reopened == nil {
		stream.close(f)
		return false
	}
	buf: [6]u8
	ok = stream.read(reopened, buf[:]) == 6 && string(buf[:]) == "reopen" && ok
	return stream.close(reopened) && ok
}

@(test)
stream_concurrent_states :: proc(t: ^testing.T) {
	when (ODIN_OS == .Windows || ODIN_OS == .Linux) && thread.IS_SUPPORTED {
		WORKERS :: 8
		ITERATIONS :: 80
		shared := stream.tmpfile()
		testing.expect(t, shared != nil, "open shared temporary stream")
		if shared == nil do return
		defer stream.close(shared)

		barrier: sync.Barrier
		sync.barrier_init(&barrier, WORKERS)
		workers: [WORKERS]Stream_Worker
		threads: [WORKERS]^thread.Thread
		for i in 0..<WORKERS {
			workers[i] = {&barrier, shared, false}
			threads[i] = thread.create(proc(th: ^thread.Thread) {
				worker := (^Stream_Worker)(th.data)
				L := io_state()
				defer kernel.close_state(L)
				sync.barrier_wait(worker.barrier)
				work_ok := true
				for i in 0..<ITERATIONS {
					f := stream.tmpfile()
					if f == nil {
						work_ok = false
						break
					}
					ok := stream.write(f, transmute([]u8)string("private")) == 7
					_, seek_ok := stream.seek(f, 0, .Start)
					buf: [7]u8
					ok = ok && seek_ok && stream.read(f, buf[:]) == 7 && string(buf[:]) == "private"
					ok = stream.close(f) && ok
					ok = stream.write(worker.shared, transmute([]u8)string("shared\n")) == 7 && ok
					if !ok || !stream.flush_all() || (i % 8 == 0 && !stream_test_reopen()) {
						work_ok = false
						break
					}
				}
				sync.barrier_wait(worker.barrier)
				if !work_ok do return
				write_command :: "sort > nul" when ODIN_OS == .Windows else "cat > /dev/null"
				src := "for i=1,4 do " +
					"local f=assert(io.popen('echo concurrent')); " +
					"assert(f:read('l')=='concurrent'); assert(f:close()); " +
					"local w=assert(io.popen('" + write_command + "','w')); " +
					"assert(w:write('data\\n')); assert(w:close()); " +
					"assert(os.execute('exit 0')) end"
				st := io_run(L, src)
				worker.ok = st == .Ok
			})
			threads[i].data = &workers[i]
		}
		for th in threads do thread.start(th)
		for th in threads do thread.destroy(th)
		for worker in workers do testing.expect(t, worker.ok, "concurrent independent state and stream operations")
		pos, ok := stream.tell(shared)
		testing.expect(t, ok && pos == WORKERS * ITERATIONS * 7, "all shared writes retained")
		_, ok = stream.seek(shared, 0, .Start)
		testing.expect(t, ok, "rewind shared stream")
		for _ in 0..<WORKERS * ITERATIONS {
			buf: [7]u8
			if stream.read(shared, buf[:]) != 7 || string(buf[:]) != "shared\n" {
				testing.expect(t, false, "shared writes are not corrupted")
				break
			}
		}
	}
}
