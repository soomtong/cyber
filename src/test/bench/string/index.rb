# frozen_string_literal: true

str = 'abcdefghijklmnopqrstuvwxyz123456' * 1_000_000 + 'waldo'

start = Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
idx = 0
50.times { idx = str.index('waldo') }

puts "time: #{Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond) - start}"
puts idx
