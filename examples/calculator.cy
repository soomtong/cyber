-- A simple calculator.
--
-- Usage:
--     cyber examples/calculator.cy
--
-- The object-oriented part: each operator is a type that implements the `Operation` trait, and a
-- `Calculator` keeps the operators and the history of its results. A new operator is added with
-- `register`, the calculator itself does not change. `describe` is a default method of the trait: an
-- operator gets it without declaring it, and `Mod` overrides it.
--
-- The functional part: `map`, `filter` and `fold` take a function value and are used with inferred
-- lambdas to query the history.

-- ---------------------------------------------------------------------------------------------------------
-- Operators.
-- ---------------------------------------------------------------------------------------------------------

type Operation trait:
    fn symbol() -> str
    fn apply(a float, b float) -> !float

    -- A default method. `self` can call the methods of the trait.
    fn describe() -> str:
        return 'operator %{self.symbol()}'

type Add:
    with Operation

fn (&Add) symbol() -> str:
    return '+'

fn (&Add) apply(a float, b float) -> !float:
    return a + b

type Sub:
    with Operation

fn (&Sub) symbol() -> str:
    return '-'

fn (&Sub) apply(a float, b float) -> !float:
    return a - b

type Mul:
    with Operation

fn (&Mul) symbol() -> str:
    return '*'

fn (&Mul) apply(a float, b float) -> !float:
    return a * b

type Div:
    with Operation

fn (&Div) symbol() -> str:
    return '/'

fn (&Div) apply(a float, b float) -> !float:
    if b == 0:
        return error.DivisionByZero
    return a / b

-- ---------------------------------------------------------------------------------------------------------
-- Calculator.
-- ---------------------------------------------------------------------------------------------------------

type Record:
    expr str
    result float

type Calculator:
    ops Map[str, ^Dyn[Operation]]
    history []Record

fn Calculator :: @init() -> Calculator:
    c := Calculator{ops = {}, history = {}}
    c.register(^Add{})
    c.register(^Sub{})
    c.register(^Mul{})
    c.register(^Div{})
    return c

fn (&&Calculator) register(op ^Dyn[Operation]):
    self.ops[op.symbol()] = op

fn (&&Calculator) calc(a float, sym str, b float) -> !float:
    op := self.ops.get(sym) ?else:
        return error.UnknownOperator
    res := op.apply(a, b)!
    self.history += Record{expr = '%{a} %{sym} %{b}', result = res}
    return res

fn (&Calculator) describe(sym str) -> str:
    op := self.ops.get(sym) ?else:
        return 'unknown operator %{sym}'
    return op.describe()

-- Evaluates an expression of the form `<number> <operator> <number>`.
fn (&&Calculator) eval(expr str) -> !float:
    parts := expr.split(' ')
    if parts.len() != 3:
        return error.InvalidExpression
    a := float.parse(parts[0])!
    b := float.parse(parts[2])!
    return self.calc(a, parts[1], b)

-- ---------------------------------------------------------------------------------------------------------
-- Functional helpers.
-- ---------------------------------------------------------------------------------------------------------

-- `T` is inferred from the items and `U` from the result type of the function or the lambda.
fn map(items []%T, f fn(T) -> %U) -> []U:
    out := []U{}
    for items |it|:
        out += f(it)
    return out

fn filter(items []%T, f fn(T) -> bool) -> []T:
    out := []T{}
    for items |it|:
        if f(it):
            out += it
    return out

fn fold(items []%T, init %A, f fn(A, T) -> A) -> A:
    acc := init
    for items |it|:
        acc = f(acc, it)
    return acc

-- ---------------------------------------------------------------------------------------------------------
-- Main.
-- ---------------------------------------------------------------------------------------------------------

-- An operator that is not one of the built-in operators of the calculator.
-- `Calculator :: @init` registers `Add`, `Sub`, `Mul` and `Div`. `Mod` is declared here, in the code that
-- uses the calculator, to show how to extend it: implement `Operation` and call `register`.
-- The code of `Calculator` does not change.
type Mod:
    with Operation

fn (&Mod) symbol() -> str:
    return '%'

fn (&Mod) apply(a float, b float) -> !float:
    if b == 0:
        return error.DivisionByZero
    return a % b

fn (&Mod) describe() -> str:
    return 'operator % (remainder)'

calc := Calculator()
calc.register(^Mod{})

for []str{'+', '%', '^'} |sym|:
    print(calc.describe(sym))

exprs := []str{'1 + 2', '10 - 4.5', '6 * 7', '9 / 2', '17 % 5', '1 / 0', '2 ^ 8', '3 +'}
for exprs |expr|:
    res := calc.eval(expr) !else |err|:
        print('%{expr} -> %{err}')
        continue
    print('%{expr} = %{res}')

-- Only the expressions that succeeded are in the history.
results := map(calc.history, |r| r.result)
print('results: %{results}')
print('sum:     %{fold(results, 0.0, |acc, x| acc + x)}')
print('max:     %{fold(results, results[0], |acc, x| if (x > acc) x else acc)}')
print('over 5:  %{filter(results, |x| x > 5.0)}')
print('doubled: %{map(results, |x| x * 2)}')
print('whole:   %{map(filter(calc.history, |r| r.result % 1 == 0), |r| r.expr).join(', ')}')
