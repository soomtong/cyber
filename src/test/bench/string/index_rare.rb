# frozen_string_literal: true

# Same as index.rb but the needle starts with a byte that never appears in the haystack.
str = 'abcdefghijklmnopqrstuvwxyz123456' * 1_000_000 + 'Waldo'

start = Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
idx = 0
50.times { idx = str.index('Waldo') }

puts "time: #{Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond) - start}"
puts idx
