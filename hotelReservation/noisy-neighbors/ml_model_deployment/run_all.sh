#!/bin/bash
INPUT_JSON="run_data_iter1_ready.json"
echo "=== Preparing shared input ==="
python3 shared_input.py "$INPUT_JSON"
echo "=== Building and Running All Inference Scenarios ==="
echo "" > results.txt

measure() {
    label=$1
    shift
    echo "Running $label ..."
    start=$(date +%s.%N)
    output=$("$@" 2>/dev/null)
    end=$(date +%s.%N)
    total=$(echo "$end - $start" | bc -l)
    result=$(echo "$output" | sed -n '1p')
    infer=$(echo "$output" | sed -n '2p')
    echo "$label result: $result"
    echo "$label inference_time: ${infer}s"
    echo "$label total_time: ${total}s"
    echo "${label}_result: $result"        >> results.txt
    echo "${label}_inference_time: $infer" >> results.txt
    echo "${label}_total_time: $total"     >> results.txt
    echo ""                                >> results.txt
}

# Python PyTorch
measure "PyTorch" python3 scenario_pytorch.py "$INPUT_JSON"
# Python ONNX
measure "ONNX_Python" python3 scenario_onnx_python.py "$INPUT_JSON"
# C++ ONNX Runtime
echo "Compiling C++ ONNX Runtime scenario..."
g++ scenario_onnx_cpp.cpp -o scenario_onnx_cpp \
    -I$ONNXRUNTIME/include \
    -L$ONNXRUNTIME/lib \
    -lonnxruntime -lcnpy -lz
measure "ONNX_CPP" ./scenario_onnx_cpp
# Go ONNX Runtime
measure "ONNX_Go" go run scenario_onnx_go.go
echo "=== All scenarios completed ==="
echo "See results.txt for full output"