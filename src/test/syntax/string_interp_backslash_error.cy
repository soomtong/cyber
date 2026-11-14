s := 'ab'
print("ends: %{s.ends_with(\"b\")}")

--cytest: error
--TokenError: A backslash can not be used inside `%{...}`: it is code, not part of the string. Write a string there with the other quote: `"%{f('b')}"`.
--
--@MainPath():2:28:
--print("ends: %{s.ends_with(\"b\")}")
--                           ^
--
