# Makefile for building perf API static libraries

CC = gcc
AR = ar
CFLAGS = -O2 -Wall -Wextra -fPIC
ARFLAGS = rcs

# Output library files
PERF_API_LIB = libperf_api.a
PERF_WINDOWED_LIB = libperf_api_windowed.a

# Object files
PERF_API_OBJ = perf_api.o
PERF_WINDOWED_OBJ = perf_api_windowed.o

# Default target: build both libraries
all: $(PERF_API_LIB) $(PERF_WINDOWED_LIB)

# Build legacy perf API library
$(PERF_API_LIB): $(PERF_API_OBJ)
	$(AR) $(ARFLAGS) $@ $<
	@echo "Built $(PERF_API_LIB)"

$(PERF_API_OBJ): perf_api.c perf_api.h
	$(CC) $(CFLAGS) -c $< -o $@

# Build windowed perf API library
$(PERF_WINDOWED_LIB): $(PERF_WINDOWED_OBJ)
	$(AR) $(ARFLAGS) $@ $<
	@echo "Built $(PERF_WINDOWED_LIB)"

$(PERF_WINDOWED_OBJ): perf_api_windowed.c perf_api_windowed.h
	$(CC) $(CFLAGS) -c $< -o $@

# Clean build artifacts
clean:
	rm -f $(PERF_API_OBJ) $(PERF_WINDOWED_OBJ) $(PERF_API_LIB) $(PERF_WINDOWED_LIB)
	@echo "Cleaned build artifacts"

# Install libraries (optional)
install: all
	@echo "Libraries built and ready for use"

.PHONY: all clean install

