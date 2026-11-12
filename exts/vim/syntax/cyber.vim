" Match language specific keywords
syntax keyword cyberKeyword
    \ if else switch case while for break continue pass begin
    \ or and not
    \ var move const global scope sink
    \ fn fnsym return self
    \ yield generator fiber suspend
    \ type struct cstruct cunion enum trait as with
    \ true false none undef void
    \ try error
    \ use

syntax match cyberComment "--.*$"

" Set highlights
highlight default link cyberKeyword Keyword
highlight default link cyberComment Comment

