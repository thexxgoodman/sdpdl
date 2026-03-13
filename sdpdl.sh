#!/bin/bash
# Provisioning script for Vast.ai
# Miniconda + envs: echomimic (py3.10), pandorapdl (py3.12)
# Структура проекта:
#   /workspace/PandoraPDL
#   /workspace/PandoraPDL/EchoMimicV2

set -eo pipefail

# ── Telegram-уведомление (опционально) ───────────────────────────────────────
# Заполни TG_BOT_TOKEN и TG_CHAT_ID — уведомление придёт когда всё готово.
# Оставь пустыми — ничего не произойдёт.
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

echo "=== [5] Install EchoMimic requirements ==="

# Находим pip для echomimic env (может быть в /venv или /opt/miniconda3/envs)
EM_PIP=""
for p in /venv/echomimic/bin/pip /opt/miniconda3/envs/echomimic/bin/pip; do
  if [ -x "$p" ]; then
    EM_PIP="$p"
    break
  fi
done

if [ -z "$EM_PIP" ]; then
  echo "ERROR: pip for echomimic env not found!" >&2
  exit 1
fi

echo "Using pip: $EM_PIP"

# Обновляем pip
"$EM_PIP" install --upgrade pip --quiet

# ВАЖНО: сначала фиксим setuptools глобально И в env —
# pip создаёт изолированные /tmp envs при сборке пакетов,
# и там тоже нужен setuptools<70
echo "=== [5.1] Fix setuptools BEFORE anything else ==="
pip install "setuptools<70" --force-reinstall --quiet || true
"$EM_PIP" install "setuptools<70" --force-reinstall --quiet

# Проверяем
"$EM_PIP" python -c "import pkg_resources; print('pkg_resources OK')" 2>/dev/null || \
  echo "WARNING: pkg_resources check failed, continuing anyway"

# PyTorch 2.5.1 + CUDA 12.4 (совместимо с драйвером 12.8 на Vast.ai)
echo "=== [5.2] Install PyTorch ==="
"$EM_PIP" install \
  torch==2.5.1 \
  torchvision==0.20.1 \
  torchaudio==2.5.1 \
  xformers==0.0.28.post3 \
  --index-url https://download.pytorch.org/whl/cu124 --quiet

# torchao для ускорения (опционально)
"$EM_PIP" install torchao \
  --index-url https://download.pytorch.org/whl/nightly/cu124 --quiet || \
  echo "WARNING: torchao install failed — continuing without it"

# clip устанавливаем отдельно с --no-build-isolation
# чтобы обойти проблему с pkg_resources в /tmp изоляции
echo "=== [5.3] Install clip ==="
"$EM_PIP" install \
  "git+https://github.com/openai/CLIP.git" \
  --no-build-isolation --quiet

# Основные зависимости EchoMimic — тоже с --no-build-isolation
echo "=== [5.4] Install EchoMimic requirements.txt ==="
"$EM_PIP" install -r requirements.txt --no-build-isolation --quiet

# Дополнительные пакеты
"$EM_PIP" install --no-deps facenet_pytorch --quiet || true
"$EM_PIP" install pyyaml --quiet

echo "=== [6] Download EchoMimic pretrained weights ==="
EM_PYTHON=""
for p in /venv/echomimic/bin/python /opt/miniconda3/envs/echomimic/bin/python; do
  if [ -x "$p" ]; then
    EM_PYTHON="$p"
    break
  fi
done

mkdir -p "$ECHOMIMIC_DIR/pretrained_weights/audio_processor"

"$EM_PYTHON" - <<'PYEOF'
import os, subprocess, sys

echomimic_dir = os.environ.get("ECHOMIMIC_DIR", "/workspace/PandoraPDL/EchoMimicV2")
weights_dir   = echomimic_dir + "/pretrained_weights"
os.makedirs(weights_dir, exist_ok=True)

# Ищем huggingface-cli рядом с текущим python
python_bin = sys.executable
hf_cli     = python_bin.replace("python", "huggingface-cli")
if not os.path.exists(hf_cli):
    hf_cli = "huggingface-cli"

def dl(repo, fname, local_dir):
    out = os.path.join(local_dir, fname)
    if os.path.exists(out) and os.path.getsize(out) > 0:
        print(f"  Already exists: {fname}")
        return
    print(f"  Downloading {fname} ...")
    subprocess.run([hf_cli, "download", repo, fname,
                    "--local-dir", local_dir], check=False)

print("[6.1] EchoMimic V2 accelerated weights")
for fname in ["denoising_unet_acc.pth", "reference_unet.pth",
              "motion_module_acc.pth", "pose_encoder.pth"]:
    dl("BadToBest/EchoMimicV2", fname, weights_dir)

print("[6.2] VAE sd-vae-ft-mse")
vae_dir = os.path.join(weights_dir, "sd-vae-ft-mse")
os.makedirs(vae_dir, exist_ok=True)
subprocess.run([hf_cli, "download", "stabilityai/sd-vae-ft-mse",
                "--local-dir", vae_dir], check=False)

print("[6.3] Whisper tiny")
audio_dir = os.path.join(weights_dir, "audio_processor")
os.makedirs(audio_dir, exist_ok=True)
whisper_path = os.path.join(audio_dir, "tiny.pt")
if not os.path.exists(whisper_path):
    subprocess.run([hf_cli, "download", "openai/whisper-tiny",
                    "--local-dir", audio_dir], check=False)
    # Переименовываем если нужно
    for candidate in ["pytorch_model.bin", "model.safetensors"]:
        src = os.path.join(audio_dir, candidate)
        if os.path.exists(src) and not os.path.exists(whisper_path):
            os.rename(src, whisper_path)
            break

print("Weights download complete.")
PYEOF

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
