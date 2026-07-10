// scenario_libtorch.cpp
#include <torch/script.h>
#include <iostream>
#include <cnpy.h>

float run_libtorch() {
    auto arr = cnpy::npy_load("input_seq.npy");
    float* data = arr.data<float>();

    torch::Tensor input = torch::from_blob(data, {1, 32, 66}).clone();

    torch::jit::script::Module model = torch::jit::load("gru_model_run1.pth");
    model.eval();

    auto out = model.forward({input}).toTensor();
    return out.item<float>();
}

int main() {
    std::cout << run_libtorch() << std::endl;
}
