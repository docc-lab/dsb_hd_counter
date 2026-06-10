import time, sys, warnings
import numpy as np
import onnxruntime as ort
from shared_input import load_scaler, load_sequence

warnings.filterwarnings("ignore")

def run_onnx_python(input_json):
    scaler = load_scaler()
    seq = load_sequence(input_json, scaler)
    sess = ort.InferenceSession("gru_model_run1.onnx", providers=["CPUExecutionProvider"])
    start = time.perf_counter()
    out = sess.run(None, {"input": seq})[0]
    elapsed = time.perf_counter() - start
    print(float(out.flat[0]))
    print(f"{elapsed:.9f}")

if __name__ == "__main__":
    run_onnx_python(sys.argv[1])