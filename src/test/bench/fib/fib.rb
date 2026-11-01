# frozen_string_literal: true

def fib(n) = n < 2 ? n : fib(n - 1) + fib(n - 2)

start = Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
res = fib(30)
puts "time: #{Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond) - start}"
puts res
