#!/bin/bash
# Provisioning script for Vast.ai
# Miniconda + envs: sadtalker (py3.10), pandorapdl (py3.12)
# Структура проекта:
#   /workspace/PandoraPDL
#   /workspace/PandoraPDL/SadTalker

set -eo pipefail

# ── Telegram-уведомление (опционально) ───────────────────────────────────────
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

echo "=== [2.1] Accept Anaconda Terms of Service ==="
set +e
conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main
conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r
set -e

echo "=== [2.2] Create envs ==="
if ! conda env list | grep -qE '^sadtalker[[:space:]]'; then
  conda create -y -n sadtalker python=3.10
else
  echo "Conda env 'sadtalker' already exists, skipping."
fi

if ! conda env list | grep -qE '^pandorapdl[[:space:]]'; then
  conda create -y -n pandorapdl python=3.12
else
  echo "Conda env 'pandorapdl' already exists, skipping."
fi

echo "=== [2.3] Activate 'sadtalker' ==="
conda activate sadtalker
python -m pip install --upgrade pip

echo "=== [3] Ensure git + ffmpeg ==="
if ! command -v git >/dev/null 2>&1 || ! command -v ffmpeg >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y git ffmpeg
    apt-get clean
  fi
fi

echo "=== [4] Clone or update SadTalker ==="
if [ ! -d "$PROJECT_DIR/SadTalker/.git" ]; then
  git clone https://github.com/OpenTalker/SadTalker.git "$PROJECT_DIR/SadTalker"
else
  echo "SadTalker already exists, pulling latest..."
  cd "$PROJECT_DIR/SadTalker"
  git pull --rebase || true
fi

cd "$PROJECT_DIR/SadTalker"

echo "=== [5] Install PyTorch for RTX 5090 (Blackwell / CUDA 12.8) FIRST ==="
# Ставим torch ДО requirements.txt — иначе requirements перезапишет его старой версией
pip install torch torchvision torchaudio \
  --index-url https://download.pytorch.org/whl/cu128 \
  --quiet
echo "Torch installed:"
python -c "import torch; print('  version:', torch.__version__); print('  CUDA:', torch.version.cuda)"

echo "=== [5.1] Install SadTalker requirements (без перезаписи torch) ==="
# Фильтруем строки с torch/torchvision/torchaudio из requirements.txt
# чтобы pip не откатил только что установленный torch 2.6+
grep -iEv '^\s*(torch|torchvision|torchaudio)' requirements.txt > /tmp/requirements_notorch.txt
echo "Filtered requirements (torch excluded):"
cat /tmp/requirements_notorch.txt
pip install -r /tmp/requirements_notorch.txt --ignore-requires-python || true

echo "=== [5.2] Install opencv-python ==="
pip install opencv-python --quiet

echo "=== [5.3] Fix pkg_resources (setuptools<70) ==="
for ST_PIP in /venv/sadtalker/bin/pip /opt/miniconda3/envs/sadtalker/bin/pip; do
  if [ -x "$ST_PIP" ]; then
    echo "Fixing setuptools via $ST_PIP ..."
    "$ST_PIP" install "setuptools<70" --force-reinstall --quiet || true
  fi
done

echo "=== [5.4] Verify torch is still correct version ==="
python -c "
import torch
v = torch.__version__
print('  torch:', v)
print('  CUDA available:', torch.cuda.is_available())
assert '2.' in v, f'ERROR: torch version is {v}, expected 2.x!'
print('  OK: torch 2.x confirmed')
"

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

echo "=== [8] Patch animate.py for fp16 + torch.compile (RTX 5090) ==="
python3 - "$PROJECT_DIR/SadTalker/src/facerender/animate.py" <<'PYEOF'
import sys
path = sys.argv[1]
text = open(path).read()

patches = [
    # Патч 1: fp16 для моделей после .to(device)
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
    # Патч 2: torch.compile после .eval()
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
    # Патч 3: входные тензоры в fp16
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
    # Патч 4: use_half=True в вызове make_animation
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

echo "=== [9] Setup conda + env vars ==="
if ! grep -q "/opt/miniconda3/bin/conda" /root/.bashrc 2>/dev/null; then
  /opt/miniconda3/bin/conda init bash || true
fi

if ! grep -q "PYTORCH_CUDA_ALLOC_CONF" /root/.bashrc 2>/dev/null; then
  echo 'export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True' >> /root/.bashrc
  echo "Added PYTORCH_CUDA_ALLOC_CONF to .bashrc"
fi

conda deactivate || true

echo ""
echo "=== [DONE] Provisioning finished ==="
echo "Project dir: $PROJECT_DIR"
echo "SadTalker:   $PROJECT_DIR/SadTalker"
echo "Envs:        sadtalker (py3.10), pandorapdl (py3.12)"
echo ""
echo "Проверь GPU:"
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
