import time, sys, torch
from gru_train import GRUContentionPredictor, N_FEATURES
from shared_input import load_scaler, load_sequence

def run_pytorch(input_json):
    scaler = load_scaler()
    seq = load_sequence(input_json, scaler)
    model = GRUContentionPredictor(input_size=N_FEATURES)
    model.load_state_dict(torch.load("gru_model_run1.pth", map_location="cpu"))
    model.eval()
    x = torch.tensor(seq)
    with torch.no_grad():
        start = time.perf_counter()
        out = model(x)
        elapsed = time.perf_counter() - start
    print(float(out.item()))
    print(f"{elapsed:.9f}")

if __name__ == "__main__":
    run_pytorch(sys.argv[1])