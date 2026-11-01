# frozen_string_literal: true

start = Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
count = 0

fibers = Array.new(100_000) do
  Fiber.new do
    count += 1
    Fiber.yield
    count += 1
  end.tap(&:resume)
end

fibers.each(&:resume)

puts "time: #{Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond) - start}"
puts count
