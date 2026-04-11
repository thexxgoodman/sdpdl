#!/bin/bash
# spdl.sh — Provisioning script for Vast.ai
#
# Что делает:
#   1. Создаёт структуру папок /workspace/Pandora/
#   2. Устанавливает conda окружение 'sadtalker' (py3.10)
#   3. Клонирует SadTalker
#   4. Устанавливает torch cu128 (RTX 5090 / Blackwell)
#   5. Устанавливает зависимости SadTalker (без перезаписи torch)
#   6. Скачивает модели SadTalker
#   7. Патчит basicsr и animate.py (fp16 + torch.compile)
#   8. Создаёт conda окружение 'demucs' (audio separation)
#
# После выполнения вручную перенести:
#   sadtalker_runner.py  → /workspace/Pandora/sadtalker/
#   audio_clean.py       → /workspace/Pandora/demucs/
#   test/                → /workspace/Pandora/sadtalker/test/

set -eo pipefail

# ── Telegram-уведомление (опционально) ───────────────────────────────────────
TG_BOT_TOKEN="8723700413:AAEbvAxPLI5iK4UlWlKf6wMVzCMTpK1jVxU"
TG_CHAT_ID="-1003856343516"
# ─────────────────────────────────────────────────────────────────────────────

echo "=== [0] Setup directories ==="
WORKSPACE="${WORKSPACE:-/workspace}"
PANDORA_DIR="$WORKSPACE/Pandora"
ST_DIR="$PANDORA_DIR/sadtalker"
ST_REPO="$ST_DIR/SadTalker"
DEMUCS_DIR="$PANDORA_DIR/demucs"

mkdir -p "$PANDORA_DIR/myproject"
mkdir -p "$ST_DIR"
mkdir -p "$ST_DIR/test/input"
mkdir -p "$ST_DIR/test/output"
mkdir -p "$ST_DIR/test/log"
mkdir -p "$DEMUCS_DIR/test/input"
mkdir -p "$DEMUCS_DIR/test/output"

echo "PANDORA_DIR  = $PANDORA_DIR"
echo "ST_DIR       = $ST_DIR"
echo "ST_REPO      = $ST_REPO"
echo "DEMUCS_DIR   = $DEMUCS_DIR"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== [1] Install Miniconda (if needed) ==="
if [ ! -x /opt/miniconda3/bin/conda ]; then
  echo "Miniconda not found, installing..."
  wget -q https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O /tmp/miniconda.sh
  bash /tmp/miniconda.sh -b -p /opt/miniconda3
  rm /tmp/miniconda.sh
else
  echo "Miniconda already installed, skipping."
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "=== [2] Init conda ==="
eval "$(/opt/miniconda3/bin/conda shell.bash hook)"

echo "=== [2.1] Accept Anaconda TOS ==="
set +e
conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main
conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r
set -e

echo "=== [2.2] Create conda env 'sadtalker' (py3.10) ==="
if ! conda env list | grep -qE '^sadtalker[[:space:]]'; then
  conda create -y -n sadtalker python=3.10
else
  echo "Conda env 'sadtalker' already exists, skipping."
fi

conda activate sadtalker
python -m pip install --upgrade pip

# ─────────────────────────────────────────────────────────────────────────────
echo "=== [3] Ensure git + ffmpeg ==="
if ! command -v git >/dev/null 2>&1 || ! command -v ffmpeg >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y git ffmpeg
    apt-get clean
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "=== [4] Clone or update SadTalker ==="
if [ ! -d "$ST_REPO/.git" ]; then
  git clone https://github.com/OpenTalker/SadTalker.git "$ST_REPO"
else
  echo "SadTalker already exists, pulling latest..."
  cd "$ST_REPO"
  git pull --rebase || true
fi

cd "$ST_REPO"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== [5] Install PyTorch for RTX 5090 (Blackwell / CUDA 12.8) FIRST ==="
pip install torch torchvision torchaudio \
  --index-url https://download.pytorch.org/whl/cu128 \
  --quiet
echo "Torch installed:"
python -c "import torch; print('  version:', torch.__version__); print('  CUDA:', torch.version.cuda)"

echo "=== [5.1] Install SadTalker requirements (без torch) ==="
grep -iEv '^\s*(torch|torchvision|torchaudio)' requirements.txt > /tmp/requirements_notorch.txt
pip install -r /tmp/requirements_notorch.txt --ignore-requires-python || true

echo "=== [5.2] Install opencv-python ==="
pip install opencv-python --quiet

echo "=== [5.3] Fix pkg_resources (setuptools<70) ==="
for ST_PIP in /venv/sadtalker/bin/pip /opt/miniconda3/envs/sadtalker/bin/pip; do
  if [ -x "$ST_PIP" ]; then
    "$ST_PIP" install "setuptools<70" --force-reinstall --quiet || true
  fi
done

echo "=== [5.4] Verify torch version ==="
python -c "
import torch
v = torch.__version__
print('  torch:', v)
print('  CUDA available:', torch.cuda.is_available())
assert '2.' in v, f'ERROR: torch version is {v}, expected 2.x!'
print('  OK: torch 2.x confirmed')
"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== [6] Download SadTalker models ==="
bash scripts/download_models.sh

echo "=== [6.1] Verify models downloaded ==="
if [ ! -f "$ST_REPO/checkpoints/SadTalker_V0.0.2_256.safetensors" ]; then
  echo "ERROR: SadTalker models not downloaded!" >&2
  exit 1
fi
echo "Models OK."

# ─────────────────────────────────────────────────────────────────────────────
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

# ─────────────────────────────────────────────────────────────────────────────
echo "=== [8] Patch animate.py for fp16 + torch.compile (RTX 5090) ==="
python3 - "$ST_REPO/src/facerender/animate.py" <<'PYEOF'
import sys
path = sys.argv[1]
text = open(path).read()

patches = [
    (
        """        generator.to(device)
        kp_extractor.to(device)
        he_estimator.to(device)
        mapping.to(device)""",
        """        generator.to(device)
        kp_extractor.to(device)
        he_estimator.to(device)
        mapping.to(device)
        if 'cuda' in device:
            generator.half()
            kp_extractor.half()
            he_estimator.half()
            mapping.half()""",
        "fp16 models"
    ),
    (
        """        self.kp_extractor.eval()
        self.generator.eval()
        self.he_estimator.eval()
        self.mapping.eval()""",
        """        self.kp_extractor.eval()
        self.generator.eval()
        self.he_estimator.eval()
        self.mapping.eval()
        if 'cuda' in device:
            self.generator = torch.compile(self.generator, mode="default")
            self.kp_extractor = torch.compile(self.kp_extractor, mode="default")
            self.he_estimator = torch.compile(self.he_estimator, mode="default")
            self.mapping = torch.compile(self.mapping, mode="default")""",
        "torch.compile"
    ),
    (
        """        source_image=source_image.to(self.device)
        source_semantics=source_semantics.to(self.device)
        target_semantics=target_semantics.to(self.device)""",
        """        source_image=source_image.to(self.device)
        source_semantics=source_semantics.to(self.device)
        target_semantics=target_semantics.to(self.device)
        if 'cuda' in self.device:
            source_image=source_image.half()
            source_semantics=source_semantics.half()
            target_semantics=target_semantics.half()""",
        "fp16 tensors"
    ),
    (
        "yaw_c_seq, pitch_c_seq, roll_c_seq, use_exp = True)",
        "yaw_c_seq, pitch_c_seq, roll_c_seq, use_exp=True, use_half=True)",
        "use_half"
    ),
]

changed = []
for old, new, name in patches:
    if old in text:
        text = text.replace(old, new)
        changed.append(name)
    else:
        print(f"  SKIP (already applied or not found): {name}")

if changed:
    open(path, 'w').write(text)
    print(f"  Applied: {', '.join(changed)}")
else:
    print("  No changes needed.")
PYEOF

conda deactivate || true

# ─────────────────────────────────────────────────────────────────────────────
echo "=== [9] Setup demucs env (audio separation) ==="

if ! conda env list | grep -qE '^demucs[[:space:]]'; then
  conda create -y -n demucs python=3.10
else
  echo "Conda env 'demucs' already exists, skipping."
fi

conda activate demucs
python -m pip install --upgrade pip

pip install torch torchvision torchaudio \
  --index-url https://download.pytorch.org/whl/cu128 \
  --quiet

pip install demucs --quiet

python -c "
import torch, demucs
print('  demucs OK')
print('  CUDA available:', torch.cuda.is_available())
print('  torch:', torch.__version__)
"

conda deactivate || true

# ─────────────────────────────────────────────────────────────────────────────
echo "=== [10] Setup conda + env vars ==="
if ! grep -q "/opt/miniconda3/bin/conda" /root/.bashrc 2>/dev/null; then
  /opt/miniconda3/bin/conda init bash || true
fi
if ! grep -q "PYTORCH_CUDA_ALLOC_CONF" /root/.bashrc 2>/dev/null; then
  echo 'export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True' >> /root/.bashrc
fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== [DONE] Provisioning finished ==="
echo ""
echo "Структура готова:"
echo "  $PANDORA_DIR/"
echo "  ├── sadtalker/"
echo "  │   ├── SadTalker/           ← готово"
echo "  │   └── test/"
echo "  │       ├── input/           ← положи audio.mp3 + face.png"
echo "  │       ├── output/"
echo "  │       └── log/"
echo "  ├── demucs/"
echo "  │   └── test/"
echo "  │       ├── input/               ← положи трек с музыкой"
echo "  │       ├── output/              ← сюда ляжет чистая речь"
echo "  │       ├── test_audio.py        ← перенести вручную"
echo "  │       └── run_test.sh          ← перенести вручную"
echo "  └── myproject/"
echo ""
echo "Далее вручную:"
echo "  1. Перенеси sadtalker_runner.py → $ST_DIR/"
echo "  2. Перенеси audio_clean.py      → $DEMUCS_DIR/"
echo "  3. Положи track.mp3 в $DEMUCS_DIR/input/"
echo "  4. conda activate demucs && python $DEMUCS_DIR/audio_clean.py $DEMUCS_DIR/input/track.mp3"

# ── Telegram-уведомление ──────────────────────────────────────────────────────
if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
  INSTANCE_ID="${VAST_CONTAINERLABEL:-$(hostname)}"
  TG_MSG="✅ Инстанс готов%0A🖥 ID: ${INSTANCE_ID}%0A📁 ${PANDORA_DIR}"
  curl -s --max-time 10 \
    "https://api.anthropic.com/bot${TG_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TG_CHAT_ID}&text=${TG_MSG}" \
    > /dev/null 2>&1 || true
fi
