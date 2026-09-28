library(cranprobe)
write_home()
print(corrupt_constant())
stopifnot(identical(fine(), 1L))
