# frozen_string_literal: true

start = Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)

list = []
1_000_000.times { list << it }

sum = 0
list.each { sum += it }

puts "time: #{Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond) - start}"
puts sum
