use os

start := os.now()!

-- Each round builds and drops an array of strings and a map, so memory that
-- an allocator reuses stays flat while a non-reusing one grows.
total := 0
for 0..200 |round|:
    arr := Array[str]{}
    for 0..5000 |i|:
        arr.append('item %{i} of round %{round}')
    m := Map[str, int]{}
    for 0..5000 |i|:
        m['k%{i}'] = i
    total += arr.len()

print('time: %{float(os.now()! - start) / 1000000}')
print(total)
