# frozen_string_literal: true

# Array-based max heap, the same algorithm as heap.cy.
Node = Data.define(:value)

class Heap
  def initialize = @nodes = []

  def insert(n)
    pos = @nodes.size
    @nodes << n
    sift_up(pos)
  end

  def pop
    top = @nodes[0]
    @nodes[0] = @nodes[-1]
    @nodes.pop
    sift_down(0)
    top
  end

  private

  def sift_up(pos)
    while pos != 0
      parent = (pos - 1) / 2
      break unless @nodes[parent].value < @nodes[pos].value

      swap(pos, parent)
      pos = parent
    end
  end

  def sift_down(pos)
    loop do
      left = pos * 2 + 1
      break if left >= @nodes.size

      if @nodes[left].value > @nodes[pos].value
        swap(pos, left)
        pos = left
        next
      end
      right = left + 1
      break if right >= @nodes.size

      if @nodes[right].value > @nodes[pos].value
        swap(pos, right)
        pos = right
        next
      end
      break
    end
  end

  def swap(a, b) = (@nodes[a], @nodes[b] = @nodes[b], @nodes[a])
end

start = Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)

h = Heap.new
(1...20_000).each { h.insert(Node.new(it)) }

sum = 0
(1...20_000).each { sum += h.pop.value }

puts "time: #{Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond) - start}"
puts sum
