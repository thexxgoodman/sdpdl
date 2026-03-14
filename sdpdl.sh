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

echo "=== [3] Ensure git + ffmpeg (system) installed ==="
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

echo "=== [4.1] Download ffmpeg-static for EchoMimic ==="
# EchoMimic использует FFMPEG_PATH для финального рендера видео.
# Скачиваем статический бинарь прямо в папку EchoMimic.
FFMPEG_STATIC_DIR="$ECHOMIMIC_DIR/ffmpeg-static"
if [ ! -d "$FFMPEG_STATIC_DIR" ]; then
  echo "Downloading ffmpeg-static..."
  cd "$ECHOMIMIC_DIR"
  wget -q https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz \
    -O /tmp/ffmpeg-static.tar.xz
  tar -xf /tmp/ffmpeg-static.tar.xz -C "$ECHOMIMIC_DIR"
  rm /tmp/ffmpeg-static.tar.xz
  # Переименовываем папку вида ffmpeg-*-amd64-static → ffmpeg-static
  for d in "$ECHOMIMIC_DIR"/ffmpeg-*-amd64-static; do
    if [ -d "$d" ]; then
      mv "$d" "$FFMPEG_STATIC_DIR"
      break
    fi
  done
  echo "ffmpeg-static installed: $FFMPEG_STATIC_DIR"
else
  echo "ffmpeg-static already exists, skipping."
fi

cd "$ECHOMIMIC_DIR"

echo "=== [5] Install EchoMimic requirements ==="

# Находим pip для echomimic env
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
"$EM_PIP" install --upgrade pip --quiet

# ВАЖНО: фиксим setuptools ПЕРВЫМ — до любых других пакетов.
# pip создаёт изолированные /tmp envs при сборке, и там тоже нужен setuptools<70.
echo "=== [5.1] Fix setuptools ==="
pip install "setuptools<70" --force-reinstall --quiet || true
"$EM_PIP" install "setuptools<70" --force-reinstall --quiet

# PyTorch nightly cu128 — необходимо для RTX 5090 (Blackwell sm_120).
# PyTorch 2.5.x stable собран только до sm_90 (H100) и падает с
# "no kernel image is available for execution on the device" на RTX 5090.
echo "=== [5.2] Install PyTorch nightly (cu128, RTX 5090 Blackwell) ==="
"$EM_PIP" install --pre torch torchvision torchaudio \
  --index-url https://download.pytorch.org/whl/nightly/cu128 \
  --force-reinstall --quiet

# torchao для дополнительного ускорения (опционально)
"$EM_PIP" install --pre torchao \
  --index-url https://download.pytorch.org/whl/nightly/cu128 --quiet || \
  echo "WARNING: torchao install failed — continuing without it"

# clip устанавливаем отдельно с --no-build-isolation
# чтобы обойти проблему с pkg_resources в /tmp изоляции
echo "=== [5.3] Install clip ==="
"$EM_PIP" install "git+https://github.com/openai/CLIP.git" \
  --no-build-isolation --quiet

# Основные зависимости EchoMimic с --no-build-isolation
echo "=== [5.4] Install EchoMimic requirements.txt ==="
"$EM_PIP" install -r requirements.txt --no-build-isolation --quiet

# Дополнительные пакеты
"$EM_PIP" install --no-deps facenet_pytorch --quiet || true
"$EM_PIP" install pyyaml --quiet

echo "=== [6] Download EchoMimic pretrained weights ==="

# Находим python для echomimic env
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

python_bin = sys.executable
hf_cli     = os.path.join(os.path.dirname(python_bin), "huggingface-cli")
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

print("[6.2] sd-image-variations-diffusers (reference UNet base)")
sd_dir = os.path.join(weights_dir, "sd-image-variations-diffusers")
os.makedirs(sd_dir, exist_ok=True)
subprocess.run([hf_cli, "download", "lambdalabs/sd-image-variations-diffusers",
                "--local-dir", sd_dir], check=False)

print("[6.3] sd-vae-ft-mse (VAE)")
vae_dir = os.path.join(weights_dir, "sd-vae-ft-mse")
os.makedirs(vae_dir, exist_ok=True)
subprocess.run([hf_cli, "download", "stabilityai/sd-vae-ft-mse",
                "--local-dir", vae_dir], check=False)

print("[6.4] Whisper tiny → ~/.cache/whisper/tiny.pt")
cache_dir = os.path.expanduser("~/.cache/whisper")
os.makedirs(cache_dir, exist_ok=True)
whisper_dst = os.path.join(cache_dir, "tiny.pt")
if not os.path.exists(whisper_dst):
    url = ("https://openaipublic.azureedge.net/main/whisper/models/"
           "65147644a518d12f04e32d6f3b26facc3f8dd46e5390956a9424a650c0ce22b9/tiny.pt")
    subprocess.run(["wget", "-q", "-O", whisper_dst, url], check=False)
    if os.path.exists(whisper_dst):
        print("  Whisper tiny downloaded OK")
    else:
        print("  WARNING: whisper tiny download failed")
else:
    print("  Already exists: tiny.pt")

print("Weights download complete.")
PYEOF

echo "=== [7] Setup conda for future shells ==="
if ! grep -q "/opt/miniconda3/bin/conda" /root/.bashrc 2>/dev/null; then
  /opt/miniconda3/bin/conda init bash || true
fi

echo "=== [DONE] Provisioning finished ==="
echo "Project dir:   $PROJECT_DIR"
echo "EchoMimic V2:  $ECHOMIMIC_DIR"
echo "ffmpeg-static: $ECHOMIMIC_DIR/ffmpeg-static"
echo "Envs:          echomimic (py3.10), pandorapdl (py3.12)"
echo "PyTorch:       nightly cu128 (RTX 5090 Blackwell)"

# ── Telegram-уведомление ──────────────────────────────────────────────────────
if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
  INSTANCE_ID="${VAST_CONTAINERLABEL:-$(hostname)}"
  TG_MSG="✅ Инстанс готов к работе%0A🖥 ID: ${INSTANCE_ID}%0A📁 ${PROJECT_DIR}%0A🎬 EchoMimic V2 установлен"
  curl -s --max-time 10 \
    "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TG_CHAT_ID}&text=${TG_MSG}" \
    > /dev/null 2>&1 || true
fi
