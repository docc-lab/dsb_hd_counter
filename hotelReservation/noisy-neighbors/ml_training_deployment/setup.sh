#!/bin/bash
set -e
LIBTORCH_VERSION="2.2.0"
ONNXRUNTIME_VERSION="1.18.0"
INSTALL_DIR="/users/$(whoami)"
TEST_DIR="$HOME/test"

echo "================================================================"
echo "  Dependency Setup Script"
echo "  Host: $(hostname)"
echo "  User: $(whoami)"
echo "================================================================"

# ── helpers ──────────────────────────────────────────────────────────
ok()   { echo "[OK]  $1"; }
warn() { echo "[WARN] $1"; }
info() { echo "[INFO] $1"; }
fail() { echo "[FAIL] $1"; exit 1; }

# ── 1. System packages ────────────────────────────────────────────────
info "Checking system packages..."
PKGS=""
command -v wget  &>/dev/null || PKGS="$PKGS wget"
command -v unzip &>/dev/null || PKGS="$PKGS unzip"
command -v bc    &>/dev/null || PKGS="$PKGS bc"
command -v cmake &>/dev/null || PKGS="$PKGS cmake"
command -v g++   &>/dev/null || PKGS="$PKGS g++"
python3 -c "import zlib" &>/dev/null || PKGS="$PKGS zlib1g-dev"

if [ -n "$PKGS" ]; then
    info "Installing: $PKGS"
    sudo apt-get update -qq && sudo apt-get install -y $PKGS
else
    ok "System packages OK"
fi

# ── 2. Python & pip ───────────────────────────────────────────────────
info "Checking Python..."
python3 --version &>/dev/null || fail "python3 not found"
ok "$(python3 --version)"

info "Checking Python packages..."
PYPKGS=""
python3 -c "import torch"        &>/dev/null || PYPKGS="$PYPKGS torch"
python3 -c "import onnxruntime"  &>/dev/null || PYPKGS="$PYPKGS onnxruntime"
python3 -c "import sklearn"      &>/dev/null || PYPKGS="$PYPKGS scikit-learn"
python3 -c "import numpy"        &>/dev/null || PYPKGS="$PYPKGS numpy"
python3 -c "import onnx"         &>/dev/null || PYPKGS="$PYPKGS onnx"

if [ -n "$PYPKGS" ]; then
    info "Installing Python packages: $PYPKGS"
    pip3 install $PYPKGS
    ok "Python packages installed"
else
    ok "Python packages OK"
fi

# ── 3. Go ─────────────────────────────────────────────────────────────
info "Checking Go..."
if ! command -v go &>/dev/null; then
    info "Go not found, installing Go 1.21..."
    wget -q https://go.dev/dl/go1.21.0.linux-amd64.tar.gz -O /tmp/go.tar.gz
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf /tmp/go.tar.gz
    export PATH=$PATH:/usr/local/go/bin
    echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
    ok "Go installed: $(go version)"
else
    ok "$(go version)"
fi

# ── 4. cnpy ───────────────────────────────────────────────────────────
info "Checking cnpy..."
CNPY_DIR="$INSTALL_DIR/cnpy_abi1"
if [ ! -f "$CNPY_DIR/lib/libcnpy.so" ]; then
    info "Building cnpy with CXX11 ABI=1..."
    cd /tmp
    rm -rf cnpy
    git clone -q https://github.com/rogersce/cnpy.git
    cd cnpy && mkdir -p build && cd build
    cmake .. \
        -DCMAKE_INSTALL_PREFIX="$CNPY_DIR" \
        -DCMAKE_CXX_FLAGS="-D_GLIBCXX_USE_CXX11_ABI=1" \
        -DCMAKE_BUILD_TYPE=Release
    make -j$(nproc) && make install
    ok "cnpy installed at $CNPY_DIR"
else
    ok "cnpy already at $CNPY_DIR"
fi

# ── 5. LibTorch ───────────────────────────────────────────────────────
info "Checking LibTorch..."
LIBTORCH_DIR="$INSTALL_DIR/libtorch"
if [ ! -f "$LIBTORCH_DIR/lib/libtorch_cpu.so" ]; then
    info "Downloading LibTorch $LIBTORCH_VERSION CPU..."
    cd "$INSTALL_DIR"
    wget -q "https://download.pytorch.org/libtorch/cpu/libtorch-cxx11-abi-shared-with-deps-${LIBTORCH_VERSION}%2Bcpu.zip" \
        -O libtorch.zip
    unzip -q libtorch.zip
    rm libtorch.zip
    ok "LibTorch installed at $LIBTORCH_DIR"
else
    ok "LibTorch already at $LIBTORCH_DIR"
fi
export LIBTORCH="$LIBTORCH_DIR"

# ── 6. ONNX Runtime C++ ───────────────────────────────────────────────
info "Checking ONNX Runtime C++..."
ORT_DIR="$INSTALL_DIR/onnxruntime-linux-x64-${ONNXRUNTIME_VERSION}"
if [ ! -f "$ORT_DIR/lib/libonnxruntime.so" ]; then
    info "Downloading ONNX Runtime $ONNXRUNTIME_VERSION..."
    cd "$INSTALL_DIR"
    wget -q "https://github.com/microsoft/onnxruntime/releases/download/v${ONNXRUNTIME_VERSION}/onnxruntime-linux-x64-${ONNXRUNTIME_VERSION}.tgz" \
        -O onnxruntime.tgz
    tar -xzf onnxruntime.tgz
    rm onnxruntime.tgz
    ok "ONNX Runtime installed at $ORT_DIR"
else
    ok "ONNX Runtime already at $ORT_DIR"
fi
export ONNXRUNTIME="$ORT_DIR"

# ── 7. Go modules ─────────────────────────────────────────────────────
info "Checking Go modules..."
cd "$TEST_DIR"
if [ ! -f "go.mod" ]; then
    go mod init test_scenarios
fi
go get github.com/yalue/onnxruntime_go@v1.10.0 2>/dev/null || true
ok "Go modules OK"

# ── 8. Export env vars permanently ───────────────────────────────────
info "Setting environment variables..."
EXPORT_BLOCK="
# === inference-bench env ===
export LIBTORCH=$LIBTORCH_DIR
export ONNXRUNTIME=$ORT_DIR
export LD_LIBRARY_PATH=$CNPY_DIR/lib:\$LIBTORCH/lib:\$LD_LIBRARY_PATH
export PATH=\$PATH:/usr/local/go/bin
# ===========================
"
if ! grep -q "inference-bench env" ~/.bashrc; then
    echo "$EXPORT_BLOCK" >> ~/.bashrc
    ok "Env vars added to ~/.bashrc"
else
    ok "Env vars already in ~/.bashrc"
fi

# apply for current session
export LD_LIBRARY_PATH="$CNPY_DIR/lib:$LIBTORCH_DIR/lib:$LD_LIBRARY_PATH"

# ── 9. Verify everything ──────────────────────────────────────────────
echo ""
echo "================================================================"
echo "  Verification"
echo "================================================================"

python3 -c "import torch; print('[OK]  PyTorch', torch.__version__)"
python3 -c "import onnxruntime; print('[OK]  ONNXRuntime', onnxruntime.__version__)"
python3 -c "import sklearn; print('[OK]  scikit-learn', sklearn.__version__)"
go version && echo "[OK]  Go OK"
[ -f "$CNPY_DIR/lib/libcnpy.so" ]           && ok "cnpy shared lib"
[ -f "$LIBTORCH_DIR/lib/libtorch_cpu.so" ]  && ok "libtorch_cpu.so"
[ -f "$ORT_DIR/lib/libonnxruntime.so" ]     && ok "libonnxruntime.so"

echo ""
echo "================================================================"
echo "  All dependencies ready!"
echo "  Run: source ~/.bashrc && ./run_all.sh"
echo "================================================================"