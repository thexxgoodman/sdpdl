#!/bin/bash
# Provisioning script for Vast.ai
# Miniconda + envs: echomimic (py3.10), pandorapdl (py3.12)
# Структура проекта:
#   /workspace/PandoraPDL
#   /workspace/PandoraPDL/EchoMimicV2

set -eo pipefail

# ── Telegram-уведомление (опционально) ───────────────────────────────────────
TG_BOT_TOKEN=""
TG_CHAT_ID=""
# ─────────────────────────────────────────────────────────────────────────────

echo "=== [0] Detect workspace and project dir ==="
WORKSPACE="${WORKSPACE:-/workspace}"
PROJECT_DIR="$WORKSPACE/PandoraPDL"
export ECHOMIMIC_DIR="$PROJECT_DIR/EchoMimicV2"

mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"

echo "WORKSPACE     = $WORKSPACE"
echo "PROJECT_DIR   = $PROJECT_DIR"
echo "ECHOMIMIC_DIR = $ECHOMIMIC_DIR"

echo "=== [1] Install Miniconda (if needed) ==="
if [ ! -x /opt/miniconda3/bin/conda ]; then
  echo "Miniconda not found, installing..."
  wget -q https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O /tmp/miniconda.sh
  bash /tmp/miniconda.sh -b -p /opt/miniconda3
  rm /tmp/miniconda.sh
else
  echo "Miniconda already installed, skipping."
fi

echo "=== [2] Init conda in bash ==="
eval "$(/opt/miniconda3/bin/conda shell.bash hook)"

echo "=== [2.1] Accept Anaconda ToS ==="
set +e
conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main
conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r
set -e

echo "=== [2.2] Create envs ==="
if ! conda env list | grep -qE '^echomimic[[:space:]]'; then
  echo "Creating conda env 'echomimic' with python=3.10..."
  conda create -y -n echomimic python=3.10
else
  echo "Conda env 'echomimic' already exists, skipping."
fi

if ! conda env list | grep -qE '^pandorapdl[[:space:]]'; then
  echo "Creating conda env 'pandorapdl' with python=3.12..."
  conda create -y -n pandorapdl python=3.12
else
  echo "Conda env 'pandorapdl' already exists, skipping."
fi

echo "=== [3] Ensure git + ffmpeg installed ==="
if ! command -v git >/dev/null 2>&1 || ! command -v ffmpeg >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y git ffmpeg
    apt-get clean
  fi
fi

echo "=== [4] Clone or update EchoMimicV2 ==="
if [ ! -d "$ECHOMIMIC_DIR/.git" ]; then
  echo "Cloning EchoMimicV2..."
  git clone https://github.com/antgroup/echomimic_v2.git "$ECHOMIMIC_DIR"
else
  echo "EchoMimicV2 already exists, pulling latest..."
  cd "$ECHOMIMIC_DIR"
  git pull --rebase || true
fi

cd "$ECHOMIMIC_DIR"

echo "=== [5] Install EchoMimic requirements into 'echomimic' env ==="
conda activate echomimic
python -m pip install --upgrade pip --quiet

# PyTorch 2.5.1 + CUDA 12.4 (совместимо с драйвером 12.8 на Vast.ai)
pip install torch==2.5.1 torchvision==0.20.1 torchaudio==2.5.1 \
    xformers==0.0.28.post3 \
    --index-url https://download.pytorch.org/whl/cu124 --quiet

# torchao для ускорения
pip install torchao --index-url https://download.pytorch.org/whl/nightly/cu124 --quiet || \
  echo "WARNING: torchao install failed — continuing without it"

pip install -r requirements.txt --quiet
pip install --no-deps facenet_pytorch --quiet || true
pip install pyyaml --quiet

echo "=== [5.1] Fix pkg_resources (setuptools<70) ==="
for PIP_PATH in /venv/echomimic/bin/pip /opt/miniconda3/envs/echomimic/bin/pip; do
  if [ -x "$PIP_PATH" ]; then
    echo "Fixing setuptools via $PIP_PATH ..."
    "$PIP_PATH" install "setuptools<70" --force-reinstall --quiet || true
  fi
done

echo "=== [6] Download EchoMimic pretrained weights ==="
python - <<'PYEOF'
import os, subprocess
weights_dir = os.environ.get("ECHOMIMIC_DIR", "/workspace/PandoraPDL/EchoMimicV2") + "/pretrained_weights"
os.makedirs(weights_dir, exist_ok=True)

files = [
    ("BadToBest/EchoMimicV2", "denoising_unet_acc.pth"),
    ("BadToBest/EchoMimicV2", "reference_unet.pth"),
    ("BadToBest/EchoMimicV2", "motion_module_acc.pth"),
    ("BadToBest/EchoMimicV2", "pose_encoder.pth"),
]
for repo, fname in files:
    out = os.path.join(weights_dir, fname)
    if not os.path.exists(out):
        print(f"Downloading {fname}...")
        subprocess.run(["huggingface-cli", "download", repo, fname,
                        "--local-dir", weights_dir], check=False)
    else:
        print(f"Already exists: {fname}")

vae_dir = os.path.join(weights_dir, "sd-vae-ft-mse")
if not os.path.isdir(vae_dir):
    print("Downloading sd-vae-ft-mse VAE...")
    subprocess.run(["huggingface-cli", "download", "stabilityai/sd-vae-ft-mse",
                    "--local-dir", vae_dir], check=False)

audio_dir = os.path.join(weights_dir, "audio_processor")
os.makedirs(audio_dir, exist_ok=True)
whisper_path = os.path.join(audio_dir, "tiny.pt")
if not os.path.exists(whisper_path):
    print("Downloading whisper tiny...")
    subprocess.run(["huggingface-cli", "download", "openai/whisper-tiny",
                    "--local-dir", audio_dir], check=False)
    pth = os.path.join(audio_dir, "pytorch_model.bin")
    if os.path.exists(pth) and not os.path.exists(whisper_path):
        os.rename(pth, whisper_path)

print("Weights download complete.")
PYEOF

conda deactivate || true

echo "=== [7] Setup conda for future shells ==="
if ! grep -q "/opt/miniconda3/bin/conda" /root/.bashrc 2>/dev/null; then
  /opt/miniconda3/bin/conda init bash || true
fi

echo "=== [DONE] Provisioning finished ==="
echo "Project dir:   $PROJECT_DIR"
echo "EchoMimic V2:  $ECHOMIMIC_DIR"
echo "Envs:          echomimic (py3.10), pandorapdl (py3.12)"

# ── Telegram-уведомление ──────────────────────────────────────────────────────
if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
  INSTANCE_ID="${VAST_CONTAINERLABEL:-$(hostname)}"
  TG_MSG="✅ Инстанс готов к работе%0A🖥 ID: ${INSTANCE_ID}%0A📁 ${PROJECT_DIR}%0A🎬 EchoMimic V2 установлен"
  curl -s --max-time 10 \
    "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TG_CHAT_ID}&text=${TG_MSG}" \
    > /dev/null 2>&1 || true
fi
