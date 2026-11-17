use os
use time
use io
use meta
use t 'test'

-- Environment variable tests (work on all platforms)
os.set_env('testfoo', 'testbar')!
t.eq(os.get_env('testfoo').?, 'testbar')
os.unset_env('testfoo')!
t.assert(os.get_env('testfoo') == none)

-- access_file()
t.eq(error.FileNotFound, os.access_file('src/test/assets/missing.txt', os.AccessExists).unwrap_error())
os.access_file('src/test/assets/file.txt', os.AccessExists)!

-- args()
-- Not available from static linking.
res := os.args()
t.eq(res.len() > 0, true)

-- exec()
-- Takes `[]str` and `[&]str`. The args are borrowed, so neither leaks (the runner checks refcounts).
if meta.system() != .windows:
    cmd := []str{'/bin/echo', 'a' + 'b'}
    er := os.exec(cmd)
    t.eq('ab\n', er.out)
    t.eq(0, er.code)
    t.eq('cd\n', os.exec([&]str{'/bin/echo', 'c' + 'd'}).out)

-- create_dir()
if os.file_exists('src/test/assets/tempdir'):
    os.remove_dir('src/test/assets/tempdir')!
os.create_dir('src/test/assets/tempdir')!

dir := os.open_dir('src/test/assets/tempdir')!
t.eq(os.FileKind.directory, dir.info()!.kind)

-- create_file() new file.
rm_res := os.remove_file('src/test/assets/write.txt')
file := os.create_file('src/test/assets/write.txt')!
_ = file.write('foobar')!
t.eq('foobar', os.read_file('src/test/assets/write.txt')!)

-- create_file() no truncate.
file = os.create_file('src/test/assets/write.txt', false)!
t.eq('foobar', os.read_file('src/test/assets/write.txt')!)

-- create_file() truncate.
file = os.create_file('src/test/assets/write.txt', true)!
t.eq('', os.read_file('src/test/assets/write.txt')!)

-- Text and bytes.
os.write_file_bytes('src/test/assets/write.txt', []byte{0x68, 0x69})!
t.eq('hi', os.read_file('src/test/assets/write.txt')!)
t.eq(2, os.read_file_bytes('src/test/assets/write.txt')!.len())
t.eq(0x69, os.read_file_bytes('src/test/assets/write.txt')![1])
os.write_file_bytes('src/test/assets/write.txt', []byte{0xff, 0xfe})!
read_err := 'none'
try:
    _ = os.read_file('src/test/assets/write.txt')!
else |err|:
    read_err = '%{err}'
t.eq('error.Unicode', read_err)
t.eq(2, os.read_file_bytes('src/test/assets/write.txt')!.len())

-- open_dir()
dir = os.open_dir('src/test')!
t.eq(os.FileKind.directory, dir.info()!.kind)

-- open_file()
file = os.open_file('src/test/assets/file.txt', .read)!
t.eq(os.FileKind.file, file.info()!.kind)

-- free() / malloc()
ptr := os.malloc(16)!
t.eq_type(Ptr[void], type.of(ptr))
os.free(ptr)

-- File.read(bytes)
file = os.open_file('src/test/assets/file.txt', .read)!
t.eq('foo', str(file.read(3)!))
t.eq('bar', str(file.read(10)!))
t.eq('', str(file.read(10)!))
-- t.eq(error.InvalidArgument, file.read(-1).unwrapError())
t.eq('', str(file.read(0)!))

-- File.read_all()
file = os.open_file('src/test/assets/file.txt', .read)!
t.eq('foobar', str(file.read_all()!))
t.eq('', str(file.read_all()!))

-- File.close()
file = os.open_file('src/test/assets/file.txt', .read)!
file.close()
t.eq(true, file.closed)

-- File.seek()
file = os.open_file('src/test/assets/file.txt', .read)!
file.seek(3)!
t.eq('bar', str(file.read(3)!))
file.seek(-6)!
t.eq('foo', str(file.read(3)!))

-- File.seek_from_end()
file = os.open_file('src/test/assets/file.txt', .read)!
file.seek_from_end(-3)!
t.eq('bar', str(file.read(3)!))
-- t.eq(error.InvalidArgument, file.seek_from_end(1).unwrapError())
file.seek_from_end(-6)!
t.eq('foo', str(file.read(3)!))

-- File.seek_from_start()
file = os.open_file('src/test/assets/file.txt', .read)!
t.eq(error.InvalidArgument, file.seek_from_start(-1).unwrap_error())
file.seek_from_start(3)!
t.eq('bar', str(file.read(3)!))

-- File.write(str) from create
file = os.create_file('src/test/assets/write.txt', true)!
_ = file.write('foobar')!
t.eq('foobar', os.read_file('src/test/assets/write.txt')!)

-- File.write(str) from open
file = os.open_file('src/test/assets/write.txt', .write)!
file.seek_from_end(0)!
_ = file.write('abcxyz')!
t.eq('foobarabcxyz', os.read_file('src/test/assets/write.txt')!)

-- File.write([&]byte) through `Dyn[io.Writer]`. Before F-22 the trait check accepted `write(str)` for this method.
fn emit(w ^Dyn[io.Writer], bytes [&]byte) -> !int:
    return w.write(bytes)
bytes := []byte{49, 50, 51}
t.eq(3, emit(^os.open_file('src/test/assets/write.txt', .write)!, bytes.span())!)
t.eq('123barabcxyz', os.read_file('src/test/assets/write.txt')!)

-- Dir.iterator()
dir = os.open_dir('src/test/assets/dir', true)!
iter := dir.iterator()
entries := Array[os.DirEntry]{}
while iter.next(&dir)! |n|:
    entries << n
t.eq(3, entries.len())
entries.sort(|a, b| a.name.less(b.name))
t.eq('dir2', entries[0].name)
t.eq(os.FileKind.directory, entries[0].kind)
t.eq('file.txt', entries[1].name)
t.eq(os.FileKind.file, entries[1].kind)
t.eq('file2.txt', entries[2].name)
t.eq(os.FileKind.file, entries[2].kind)

-- -- Dir.walk()
-- dir = os.open_dir('src/test/assets/dir', true)!
-- iter = dir.walk()
-- entries = {}
-- while iter.next() -> n:
--     entries.append(n)
-- t.eq(4, entries.len())
-- entries.sort((a, b) => a.path.less(b.path))
-- t.eq('dir2', entries[0].path)
-- if meta.system() == .windows:
--     t.eq('dir2\file.txt', entries[1].path)
-- else:
--     t.eq('dir2/file.txt', entries[1].path)
-- t.eq('file.txt', entries[2].path)
-- t.eq('file2.txt', entries[3].path)

-- File times as `time.Time`.
os.write_file('src/test/assets/write.txt', 'x')!
info := os.file_info('src/test/assets/write.txt')!
mt := time.unix(info.mtime_sec, info.mtime_nsec)!
t.eq(info.mtime_sec, mt.unix())
t.eq(info.mtime_nsec, mt.subsec_nanos())
age := time.now() - mt
t.eq(true, age < time.minutes(10))
t.eq(true, age > time.minutes(-10))
old := os.file_info('src/test/assets/file.txt')!
t.eq(true, time.unix(old.mtime_sec, old.mtime_nsec)! <= mt)

-- writeFile(str)
if meta.cpu() != 'wasm32':
    s := 'hello'
    os.write_file('test.txt', s)!
    file := os.open_file('test.txt', .read)!
    t.eq('hello', str(file.read_all()!))

--cytest: pass