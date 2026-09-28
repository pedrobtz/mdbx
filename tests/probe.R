library(cranprobe)
print(corrupt_constant())
stopifnot(identical(fine(), 1L))
