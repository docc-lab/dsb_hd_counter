CC = gcc
CFLAGS = -std=c11 -O2 -Wall -Wextra
AR = ar
ARFLAGS = rcs

TARGET = libperf_api.a
OBJS = perf_api.o

all: $(TARGET)

$(TARGET): $(OBJS)
	$(AR) $(ARFLAGS) $@ $^

perf_api.o: perf_api.c perf_api.h
	$(CC) $(CFLAGS) -c perf_api.c -o perf_api.o

clean:
	rm -f $(OBJS) $(TARGET)

test: $(TARGET) test_perf.c
	$(CC) $(CFLAGS) test_perf.c -o test_perf -L. -lperf_api

.PHONY: all clean test

