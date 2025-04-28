gcc -c -o perf_api.o perf_api.c


ar rcs libperf_api.a perf_api.o


go run main.go
