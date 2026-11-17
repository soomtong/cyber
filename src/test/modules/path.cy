use t 'test'
use path

t.eq(path.join('a', 'b'), 'a/b')
t.eq(path.join('a/', '/b'), 'a/b')
t.eq(path.join('/a', '../b'), '/b')
t.eq(path.join('', 'b'), 'b')
t.eq(path.join('', ''), '')
t.eq(path.join({'a', 'b', 'c.txt'}), 'a/b/c.txt')
t.eq(path.join('src', 'std/path.cy'), 'src/std/path.cy')

t.eq(path.normalize(''), '.')
t.eq(path.normalize('.'), '.')
t.eq(path.normalize('/'), '/')
t.eq(path.normalize('//'), '/')
t.eq(path.normalize('a//b/./../c/'), 'a/c')
t.eq(path.normalize('../a/..'), '..')
t.eq(path.normalize('../../a'), '../../a')
t.eq(path.normalize('/../a'), '/a')
t.eq(path.normalize('a/..'), '.')

t.eq(path.base(''), '.')
t.eq(path.base('/'), '/')
t.eq(path.base('a'), 'a')
t.eq(path.base('a/b/'), 'b')
t.eq(path.base('/a/b.txt'), 'b.txt')

t.eq(path.dir(''), '.')
t.eq(path.dir('a'), '.')
t.eq(path.dir('/'), '/')
t.eq(path.dir('/a'), '/')
t.eq(path.dir('a/b/'), 'a')
t.eq(path.dir('a/b/c.txt'), 'a/b')
t.eq(path.dir('a//b'), 'a')

t.eq(path.ext('a/b.tar.gz'), '.gz')
t.eq(path.ext('a/b'), '')
t.eq(path.ext('.bashrc'), '')
t.eq(path.ext('a.'), '.')
t.eq(path.ext('..'), '')
t.eq(path.ext('a.d/b'), '')

t.eq(path.stem('a/b.tar.gz'), 'b.tar')
t.eq(path.stem('.bashrc'), '.bashrc')
t.eq(path.stem('a/b'), 'b')

t.assert(path.is_absolute('/usr'))
t.assert(!path.is_absolute('usr'))
t.assert(!path.is_absolute(''))

--cytest: pass
