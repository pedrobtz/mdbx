corrupt_constant <- function() { x <- "pristine"; .Call(C_corrupt, x); x }
write_home <- function() { f <- file.path(system.file(package = "cranprobe"), "probe.txt"); writeLines("x", f); file.remove(f); invisible(TRUE) }
fine <- function() 1L
