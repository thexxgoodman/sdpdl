#!/bin/bash
# Provisioning script for Vast.ai
# Miniconda + envs: sadtalker (py3.10), pandorapdl (py3.12)
# Структура проекта:
#   /workspace/PandoraPDL
#   /workspace/PandoraPDL/SadTalker

set -eo pipefail

# ── Telegram-уведомление (опционально) ───────────────────────────────────────
# Заполни TG_BOT_TOKEN и TG_CHAT_ID — и уведомление будет отправлено.
# Оставь пустыми — ничего не произойдёт, ошибок не будет.
TG_BOT_TOKEN=""
TG_CHAT_ID=""
# ─────────────────────────────────────────────────────────────────────────────

echo "=== [0] Detect workspace and project dir ==="
WORKSPACE="${WORKSPACE:-/workspace}"
PROJECT_DIR="$WORKSPACE/PandoraPDL"

mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"

echo "WORKSPACE   = $WORKSPACE"
echo "PROJECT_DIR = $PROJECT_DIR"

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

echo "=== [2.1] Accept Anaconda Terms of Service for defaults (non-interactive) ==="
set +e
conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main
conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r
set -e

echo "=== [2.2] Create envs 'sadtalker' (py3.10) and 'pandorapdl' (py3.12) ==="
if ! conda env list | grep -qE '^sadtalker[[:space:]]'; then
  echo "Creating conda env 'sadtalker' with python=3.10..."
  conda create -y -n sadtalker python=3.10
else
  echo "Conda env 'sadtalker' already exists, skipping create."
fi

if ! conda env list | grep -qE '^pandorapdl[[:space:]]'; then
  echo "Creating conda env 'pandorapdl' with python=3.12..."
  conda create -y -n pandorapdl python=3.12
else
  echo "Conda env 'pandorapdl' already exists, skipping create."
fi

echo "=== [2.3] Activate 'sadtalker' env for SadTalker setup ==="
conda activate sadtalker
python -m pip install --upgrade pip

echo "=== [3] Ensure git + ffmpeg installed ==="
if ! command -v git >/dev/null 2>&1 || ! command -v ffmpeg >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y git ffmpeg
    apt-get clean
  else
    echo "apt-get not available, assume git/ffmpeg already present or install manually."
  fi
fi

echo "=== [4] Clone or update SadTalker in $PROJECT_DIR/SadTalker ==="
if [ ! -d "$PROJECT_DIR/SadTalker/.git" ]; then
  echo "Cloning SadTalker..."
  git clone https://github.com/OpenTalker/SadTalker.git "$PROJECT_DIR/SadTalker"
else
  echo "SadTalker already exists, pulling latest..."
  cd "$PROJECT_DIR/SadTalker"
  git pull --rebase || true
fi

cd "$PROJECT_DIR/SadTalker"

echo "=== [5] Install SadTalker requirements into conda env 'sadtalker' ==="
# Исключаем torch из requirements.txt — поставим совместимую версию вручную ниже
pip install -r requirements.txt --ignore-requires-python || true

echo "=== [5.1] Install PyTorch for RTX 5090 (Blackwell / CUDA 12.8) ==="
# Официальный SadTalker тянет torch ~1.x–2.0 — он не поддерживает архитектуру
# Blackwell (sm_120). Принудительно ставим torch 2.6+ с cu128.
pip install torch torchvision torchaudio \
  --index-url https://download.pytorch.org/whl/cu128 \
  --force-reinstall --quiet
echo "Torch installed:"
python -c "import torch; print('  version:', torch.__version__); print('  CUDA:', torch.version.cuda)"

echo "=== [5.2] Fix pkg_resources (setuptools<70) ==="
# setuptools>=70 убрал pkg_resources из публичного API — librosa на нём падает.
for ST_PIP in /venv/sadtalker/bin/pip /opt/miniconda3/envs/sadtalker/bin/pip; do
  if [ -x "$ST_PIP" ]; then
    echo "Fixing setuptools via $ST_PIP ..."
    "$ST_PIP" install "setuptools<70" --force-reinstall --quiet || true
  fi
done

echo "=== [6] Download SadTalker models ==="
bash scripts/download_models.sh

echo "=== [7] Fix basicsr rgb_to_grayscale import ==="
CANDIDATES=(
  "/venv/sadtalker/lib/python3.10/site-packages/basicsr/data/degradations.py"
  "/opt/miniconda3/envs/sadtalker/lib/python3.10/site-packages/basicsr/data/degradations.py"
)
for f in "${CANDIDATES[@]}"; do
  if [ -f "$f" ]; then
    echo "Patching $f ..."
    sed -i \
      's/from torchvision.transforms.functional_tensor import rgb_to_grayscale/from torchvision.transforms.functional import rgb_to_grayscale/' \
      "$f" || true
  fi
done

echo "=== [8] Setup conda for future shells (without auto-activation) ==="
if ! grep -q "/opt/miniconda3/bin/conda" /root/.bashrc 2>/dev/null; then
  /opt/miniconda3/bin/conda init bash || true
fi

# ── Оптимизация памяти GPU для RTX 5090 ──────────────────────────────────────
# expandable_segments снижает фрагментацию VRAM при больших батчах.
if ! grep -q "PYTORCH_CUDA_ALLOC_CONF" /root/.bashrc 2>/dev/null; then
  echo 'export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True' >> /root/.bashrc
  echo "Added PYTORCH_CUDA_ALLOC_CONF to .bashrc"
fi

conda deactivate || true

echo "=== [DONE] Provisioning finished ==="
echo "Project dir: $PROJECT_DIR"
echo "SadTalker:   $PROJECT_DIR/SadTalker"
echo "Envs:        sadtalker (py3.10), pandorapdl (py3.12)"
echo ""
echo "Проверь GPU после провижнинга:"
echo "  conda activate sadtalker"
echo "  python -c \"import torch; print(torch.__version__, torch.cuda.get_device_name(0))\""

# ── Telegram-уведомление ──────────────────────────────────────────────────────
if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
  INSTANCE_ID="${VAST_CONTAINERLABEL:-$(hostname)}"
  TG_MSG="✅ Инстанс готов к работе%0A🖥 ID: ${INSTANCE_ID}%0A📁 ${PROJECT_DIR}"
  curl -s --max-time 10 \
    "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TG_CHAT_ID}&text=${TG_MSG}" \
    > /dev/null 2>&1 || true
fi
