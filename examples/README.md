In this directory, you'll find a collection of Cyber script examples.

You can find benchmark code compared with other languages [here](https://github.com/fubark/cyber/tree/master/test/bench).

Notable examples will be listed here:
- [asteroids.cy](https://github.com/fubark/ray-cyber/blob/master/examples/asteroids.cys) - The classic asteroids game.
- [cyber-tack](https://github.com/sts10/cyber-tack) - Tic tac toe with a Cyber tutorial.
- [snake.cy](https://github.com/fubark/ray-cyber/blob/master/examples/snake.cys) - The classic snake game ported from RayLib's game demo site.
- [calculator.cy](calculator.cy) - A simple calculator with trait based operators and `map`, `filter`, `fold` helpers.
- [fmt.cy](fmt.cy) - A source formatter for Cyber written in Cyber. A token-based sibling of the built-in `cyber fmt`.
- [commands.cy](commands.cy) - Runs other programs with `os.cmd`: pipes, input text, exit codes, files for the streams and a time limit.
- [stream_lines.cy](stream_lines.cy) - Reads the output of a running program a line at a time with `Cmd.start`, and stops it early.
- [build_log.cy](build_log.cy) - Keeps stdout and stderr together in their order with `Cmd.stderr_to_stdout`: lines, a log file and a pipe.
- [background_job.cy](background_job.cy) - Starts a server that keeps running with `Cmd.detach`, talks to it and stops it by its process id.
- [parallel_jobs.cy](parallel_jobs.cy) - Runs several commands at once with `Cmd.start`, keeps them in an `Array[os.Process]` and reports each exit code.
- [pi_digits.cy](pi_digits.cy) - Prints PI to the Nth decimal place with an integer spigot. The number comes from an argument, a prompt or a pipe (`os.input`).
- [e_digits.cy](e_digits.cy) - Prints e to the Nth decimal place with Sale's spigot, the sibling of `pi_digits.cy`.
- [fibonacci_sequence.cy](fibonacci_sequence.cy) - Prints the first N Fibonacci numbers, up to the 93 that fit in an `int` (one more overflows).
- [prime_factors.cy](prime_factors.cy) - Factors a number up to 10^12 into primes by trial division and prints it as a product of powers.
- [next_prime.cy](next_prime.cy) - Prints primes one at a time from a `generator fn` until you stop asking, or N of them from an argument.
- [tile_cost.cy](tile_cost.cy) - Works out what the tile for a floor costs from its width, length and price per m², with money in cents (`float.fmt({places=2})`).
- [mortgage.cy](mortgage.cy) - Works out the monthly payment of a mortgage, or how long a payment takes to pay it back, month by month in cents.
