#include <onnxruntime_cxx_api.h>
#include <cnpy.h>
#include <iostream>
#include <chrono>

int main() {
    auto arr = cnpy::npy_load("input_seq.npy");
    float* data = arr.data<float>();

    Ort::Env env(ORT_LOGGING_LEVEL_WARNING, "gru");
    Ort::SessionOptions opts;
    Ort::Session session(env, "gru_model_run1.onnx", opts);

    std::vector<int64_t> shape = {1, 50, 68};
    Ort::MemoryInfo mem = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
    auto input_tensor = Ort::Value::CreateTensor<float>(
        mem, data, 1*50*68, shape.data(), shape.size());

    const char* in_names[]  = {"input"};
    const char* out_names[] = {"p50_score"};

    auto t1 = std::chrono::high_resolution_clock::now();
    auto output = session.Run(Ort::RunOptions{nullptr},
                              in_names, &input_tensor, 1,
                              out_names, 1);
    auto t2 = std::chrono::high_resolution_clock::now();

    double elapsed = std::chrono::duration<double>(t2 - t1).count();
    float* out = output[0].GetTensorMutableData<float>();

    std::cout << out[0] << "\n";
    std::cout << elapsed << "\n";
}