-- Works out the monthly payment of a fixed rate mortgage, or how long a monthly payment takes to pay one back.
-- The mode and the numbers come from the command line, from prompts at a terminal or from lines of a pipe:
--   cyber examples/mortgage.cy payment 300000 6.5 30     (loan, yearly interest in %, years)
--   cyber examples/mortgage.cy payoff 300000 6.5 2500    (loan, yearly interest in %, monthly payment)
--   cyber examples/mortgage.cy
use math
use os

const MaxMoney = 1_000_000_000.0
const MaxYears = 50
const MaxMonths = MaxYears * 12

-- Money is kept in cents, so each month's interest rounds to a cent like a bank statement.
fn cents(x float) -> int:
    return int(math.round(x * 100))

-- `c` cents as money with the digits in groups of three: 1,896.21.
fn money(c int) -> str:
    return (c / 100.0).fmt({places=2, sep=','})

-- A number that the program asks for. Only the interest rate can be 0.
type Field:
    name      str
    max       float
    zero_ok   bool = false

const Loan     = Field{name='Loan amount', max=MaxMoney}
const Interest = Field{name='Yearly interest (%)', max=100.0, zero_ok=true}
const Years    = Field{name='Years', max=float(MaxYears)}
const Payment  = Field{name='Monthly payment', max=MaxMoney}

type Mode enum:
    -- The monthly payment that pays the loan back in a number of years.
    case payment
    -- How long a monthly payment takes to pay the loan back.
    case payoff

fn (Mode) fields() -> [3]Field:
    return switch self:
        case .payment => {Loan, Interest, Years}
        case .payoff  => {Loan, Interest, Payment}

-- A loan of `amount` cents at a `rate` of interest a month: 0.005 for 6% a year.
type Mortgage:
    amount int
    rate   float

-- The interest of a month on `balance` cents, to the cent.
fn (&Mortgage) interest(balance int) -> int:
    return int(math.round(balance * self.rate))

-- The payment that pays the loan back in `months`, rounded up to a cent so that the last payment is not larger.
fn (&Mortgage) payment(months int) -> int:
    if self.rate == 0:
        return (self.amount + months - 1) / months
    growth := (1 + self.rate) ** float(months)
    return int(math.ceil(self.amount * self.rate * growth / (growth - 1)))

-- The payments that pay the loan back: how many, the last one, which can be smaller, and the interest of them all.
type Payoff:
    months   int
    last     int
    interest int

-- Pays `payment` each month until nothing is owed, or `none` when that takes more than `MaxYears`.
fn (&Mortgage) pay_off(payment int) -> ?Payoff:
    balance, months, last, total := self.amount, 0, 0, 0
    while balance > 0:
        if months == MaxMonths:
            return none
        interest := self.interest(balance)
        total += interest
        balance += interest
        last = if (payment < balance) payment else balance
        balance -= last
        months += 1
    return Payoff{months=months, last=last, interest=total}

-- `n` of `word`: 1 year, 2 years.
fn count(n int, word str) -> str:
    return if (n == 1) '1 %{word}' else '%{n} %{word}s'

-- `months` in years and months: 24 years and 9 months.
fn duration(months int) -> str:
    years, rest := months / 12, months % 12
    var parts []str = {}
    if years > 0:
        parts += count(years, 'year')
    if rest > 0:
        parts += count(rest, 'month')
    return parts.join(' and ')

-- What the payments come to, and the last one when it is smaller.
fn print_totals(loan Mortgage, payment int, paid Payoff):
    if paid.last < payment:
        print('The last payment:  %{money(paid.last)}')
    print('Total interest:    %{money(paid.interest)}')
    print('Total paid:        %{money(loan.amount + paid.interest)}')

-- The number in `text` for `field`, or `none` after saying what is wrong with it.
fn parse_field(field Field, text str) -> ?float:
    x := float.parse(text.trim()) !else:
        eprint('`%{text.trim()}` is not a number.')
        return none
    low_ok := if (field.zero_ok) x >= 0 else x > 0
    -- Written so that NaN, which passes no comparison, is turned away too.
    if !(low_ok and x <= field.max):
        bound := if (field.zero_ok) 'at least 0' else 'above 0'
        eprint('%{field.name} must be %{bound} and at most %{field.max.fmt({places=0, sep=','})}.')
        return none
    return x

fn parse_mode(text str) -> ?Mode:
    switch text.trim():
        case 'payment':
            return .payment
        case 'payoff':
            return .payoff
        else:
            eprint('Choose `payment` or `payoff`, found `%{text.trim()}`.')
            return none

-- Asks for `field` until the answer is good at a terminal. From a pipe, the next line decides.
fn ask_field(field Field) -> !?float:
    while os.input('%{field.name}: ')! |line|:
        if parse_field(field, line) |x|:
            return x
        if !os.stdin().is_terminal():
            return none
    return none

-- Asks for the mode in the same way.
fn ask_mode() -> !?Mode:
    while os.input('Find the monthly payment or the payoff time? (payment/payoff) ')! |line|:
        if parse_mode(line) |mode|:
            return mode
        if !os.stdin().is_terminal():
            return none
    return none

-- The numbers of `fields`, from `texts` or from the input when `texts` is empty.
fn read_numbers(fields [3]Field, texts []str) -> !?[]float:
    if texts.len() > 0 and texts.len() != fields.len():
        var names []str = {}
        for fields |field|:
            names += field.name
        eprint('Expected %{fields.len()} numbers: %{names.join(', ')}. Give none to be asked for them.')
        return none
    var numbers []float = {}
    for fields |i, field|:
        x := (if (texts.len() > 0) parse_field(field, texts[i]) else ask_field(field)!) ?else return none
        numbers += x
    return numbers

-- A part of a month counts as a whole one, so 0.01 years is 1 month.
fn print_payment(loan Mortgage, years float):
    months := int(math.ceil(years * 12))
    payment := loan.payment(months)
    paid := loan.pay_off(payment).?
    print('Monthly payment:   %{money(payment)} for %{duration(months)}')
    print_totals(loan, payment, paid)

-- Whether `payment` pays the loan back, after printing how long that takes or why it does not.
fn print_payoff(loan Mortgage, payment int) -> bool:
    first := loan.interest(loan.amount)
    if payment <= first:
        eprint('A payment of %{money(payment)} does not cover the first month\'s interest of %{money(first)}.')
        return false
    paid := loan.pay_off(payment) ?else:
        eprint('A payment of %{money(payment)} takes more than %{MaxYears} years.')
        return false
    print('Paid off in:       %{duration(paid.months)}, %{count(paid.months, 'payment')}')
    print_totals(loan, payment, paid)
    return true

fn main() -> !void:
    args := os.args()
    mode := (if (args.len() > 1) parse_mode(args[1]) else ask_mode()!) ?else os.exit(1)
    texts := if (args.len() > 1) args[2..] else args[1..]
    numbers := read_numbers(mode.fields(), texts)! ?else os.exit(1)
    loan := Mortgage{amount=cents(numbers[0]), rate=numbers[1] / 100 / 12}
    if mode == .payment:
        print_payment(loan, numbers[2])
    else !print_payoff(loan, cents(numbers[2])):
        os.exit(1)
