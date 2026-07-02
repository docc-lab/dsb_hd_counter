# Makefile for building perf API static libraries

CC = gcc
AR = ar
CFLAGS = -O2 -Wall -Wextra -fPIC
ARFLAGS = rcs

# Output library files
PERF_API_LIB = libperf_api.a
PERF_WINDOWED_LIB = libperf_api_windowed.a
MSR_READER_LIB = libmsr_reader.a

# Object files
PERF_API_OBJ = perf_api.o
PERF_WINDOWED_OBJ = perf_api_windowed.o
MSR_READER_OBJ = msr_reader.o

# Default target: build all libraries (windowed_sampler.go links
# -lperf_api_windowed AND -lmsr_reader unconditionally, so every service
# binary needs all three)
all: $(PERF_API_LIB) $(PERF_WINDOWED_LIB) $(MSR_READER_LIB)

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

# Build MSR reader library (frequency utilization sampling)
$(MSR_READER_LIB): $(MSR_READER_OBJ)
	$(AR) $(ARFLAGS) $@ $<
	@echo "Built $(MSR_READER_LIB)"

$(MSR_READER_OBJ): msr_reader.c msr_reader.h
	$(CC) $(CFLAGS) -c $< -o $@

# Clean build artifacts
clean:
	rm -f $(PERF_API_OBJ) $(PERF_WINDOWED_OBJ) $(MSR_READER_OBJ) $(PERF_API_LIB) $(PERF_WINDOWED_LIB) $(MSR_READER_LIB)
	@echo "Cleaned build artifacts"

# Install libraries (optional)
install: all
	@echo "Libraries built and ready for use"

.PHONY: all clean install

