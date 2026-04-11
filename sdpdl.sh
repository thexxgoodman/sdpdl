#!/bin/bash
# spdl.sh — Provisioning script for Vast.ai
#
# Окружения:
#   sadtalker (py3.10) — SadTalker + оптимизации RTX 5090
#   demucs    (py3.10) — audio separation
#
# После выполнения вручную перенести:
#   sadtalker_runner.py → /workspace/Pandora/sadtalker/
#   test/* файлы        → /workspace/Pandora/sadtalker/test/

set -eo pipefail

# ── Telegram ─────────────────────────────────────────────────────────────────
TG_BOT_TOKEN=""
TG_CHAT_ID=""

tg_send() {
  local msg="$1"
  if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
    local INSTANCE_ID="${VAST_CONTAINERLABEL:-$(hostname)}"
    curl -s --max-time 10 \
      "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
      -d "chat_id=${TG_CHAT_ID}&text=${INSTANCE_ID}%0A${msg}&parse_mode=HTML" \
      > /dev/null 2>&1 || true
  fi
}

tg_error() {
  local step="$1"
  local detail="$2"
  tg_send "❌ Ошибка на шаге: <b>${step}</b>%0A%0A${detail}"
  echo "ERROR: $step — $detail" >&2
}

tg_ok() {
  local msg="$1"
  tg_send "✅ ${msg}"
}

# Глобальный перехват ошибок — если что-то упало без явной обработки
trap 'tg_error "НЕОЖИДАННАЯ ОШИБКА" "Строка $LINENO — скрипт завершился аварийно"' ERR
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
mkdir -p "$DEMUCS_DIR/test/log"

echo "PANDORA_DIR = $PANDORA_DIR"
echo "ST_DIR      = $ST_DIR"
echo "ST_REPO     = $ST_REPO"
echo "DEMUCS_DIR  = $DEMUCS_DIR"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== [1] Install Miniconda (if needed) ==="
if [ ! -x /opt/miniconda3/bin/conda ]; then
  echo "Miniconda not found, installing..."
  wget -q https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O /tmp/miniconda.sh \
    || { tg_error "[1] Miniconda" "Не удалось скачать установщик Miniconda"; exit 1; }
  bash /tmp/miniconda.sh -b -p /opt/miniconda3 \
    || { tg_error "[1] Miniconda" "Ошибка установки Miniconda"; exit 1; }
  rm /tmp/miniconda.sh
else
  echo "Miniconda already installed, skipping."
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "=== [2] Init conda ==="
eval "$(/opt/miniconda3/bin/conda shell.bash hook)" \
  || { tg_error "[2] Conda init" "Не удалось инициализировать conda"; exit 1; }

set +e
conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main
conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r
set -e

echo "=== [2.2] Create conda envs (py3.10) ==="
if ! conda env list | grep -qE '^sadtalker[[:space:]]'; then
  conda create -y -n sadtalker python=3.10 \
    || { tg_error "[2.2] conda create sadtalker" "Ошибка создания окружения sadtalker"; exit 1; }
else
  echo "Conda env 'sadtalker' already exists, skipping."
fi

if ! conda env list | grep -qE '^demucs[[:space:]]'; then
  conda create -y -n demucs python=3.10 \
    || { tg_error "[2.2] conda create demucs" "Ошибка создания окружения demucs"; exit 1; }
else
  echo "Conda env 'demucs' already exists, skipping."
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "=== [3] Ensure git + ffmpeg ==="
if ! command -v git >/dev/null 2>&1 || ! command -v ffmpeg >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y git ffmpeg \
      || { tg_error "[3] apt-get" "Ошибка установки git/ffmpeg"; exit 1; }
    apt-get clean
  fi
fi

# ═════════════════════════════════════════════════════════════════════════════
#  SADTALKER
# ═════════════════════════════════════════════════════════════════════════════
conda activate sadtalker
python -m pip install --upgrade pip --quiet

echo "=== [4] Clone or update SadTalker ==="
if [ ! -d "$ST_REPO/.git" ]; then
  git clone https://github.com/OpenTalker/SadTalker.git "$ST_REPO" \
    || { tg_error "[4] git clone SadTalker" "Не удалось клонировать репозиторий SadTalker"; exit 1; }
else
  echo "SadTalker already exists, pulling latest..."
  cd "$ST_REPO"
  git pull --rebase || true
fi
cd "$ST_REPO"

echo "=== [5] Install PyTorch (cu128) ==="
pip install torch torchvision torchaudio \
  --index-url https://download.pytorch.org/whl/cu128 \
  --quiet \
  || { tg_error "[5] torch install" "Ошибка установки PyTorch cu128 в sadtalker"; exit 1; }

TORCH_VER=$(python -c "import torch; print(torch.__version__)")
python -c "import torch; assert '2.' in torch.__version__, 'wrong version'" \
  || { tg_error "[5] torch verify" "Неверная версия torch: ${TORCH_VER}"; exit 1; }
echo "  torch: $TORCH_VER OK"

echo "=== [5.1] Pin problematic packages for py3.10 ==="
# scikit-learn>=1.6, PyWavelets>=1.8, pandas>=2.3 требуют Python 3.11+
# Создаём constraints файл — блокирует версии даже для транзитивных зависимостей
# (когда другой пакет тянет scikit-learn как зависимость — pip всё равно возьмёт <1.6)
cat > /tmp/constraints.txt <<'EOF'
scikit-learn<1.6
PyWavelets<1.8
pandas<2.3
numpy<2.0
EOF

pip install \
  "scikit-learn<1.6" \
  "PyWavelets<1.8" \
  "pandas<2.3" \
  "numpy<2.0" \
  --quiet \
  || { tg_error "[5.1] pin packages" "Ошибка пинирования scikit-learn/PyWavelets/pandas/numpy"; exit 1; }
echo "  Pinned packages OK."

echo "=== [5.2] Install SadTalker requirements ==="
# Фильтруем пинованные пакеты из requirements
# --constraint гарантирует что даже транзитивные зависимости не выйдут за пины
grep -iEv '^\s*(torch|torchvision|torchaudio|scikit.learn|sklearn|pywavelets|pandas|numpy)' \
  requirements.txt > /tmp/requirements_notorch.txt
pip install -r /tmp/requirements_notorch.txt \
  --constraint /tmp/constraints.txt \
  --ignore-requires-python \
  || { tg_error "[5.2] requirements" "Ошибка установки зависимостей SadTalker"; exit 1; }
echo "  SadTalker requirements OK."

echo "=== [5.3] Install opencv ==="
pip install opencv-python --quiet \
  || { tg_error "[5.3] opencv" "Ошибка установки opencv-python"; exit 1; }

echo "=== [5.4] Fix setuptools ==="
for ST_PIP in /venv/sadtalker/bin/pip /opt/miniconda3/envs/sadtalker/bin/pip; do
  if [ -x "$ST_PIP" ]; then
    "$ST_PIP" install "setuptools<70" --force-reinstall --quiet || true
  fi
done

echo "=== [5.5] Verify sadtalker deps ==="
python -c "
import torch, tqdm, cv2, numpy, pandas, sklearn
print('  torch:', torch.__version__)
print('  numpy:', numpy.__version__)
print('  CUDA:', torch.cuda.is_available())
assert '2.' in torch.__version__
print('  OK')
" || { tg_error "[5.5] verify sadtalker" "Проверка зависимостей sadtalker провалилась — что-то не установилось"; exit 1; }

echo "=== [6] Download SadTalker models ==="
bash scripts/download_models.sh \
  || { tg_error "[6] download models" "Ошибка скачивания моделей SadTalker"; exit 1; }

echo "=== [6.1] Verify models ==="
if [ ! -f "$ST_REPO/checkpoints/SadTalker_V0.0.2_256.safetensors" ]; then
  tg_error "[6.1] models verify" "Модели SadTalker не скачались — файл SadTalker_V0.0.2_256.safetensors отсутствует"
  exit 1
fi
echo "  Models OK."

echo "=== [7] Fix basicsr ==="
CANDIDATES=(
  "/venv/sadtalker/lib/python3.10/site-packages/basicsr/data/degradations.py"
  "/opt/miniconda3/envs/sadtalker/lib/python3.10/site-packages/basicsr/data/degradations.py"
)
for f in "${CANDIDATES[@]}"; do
  if [ -f "$f" ]; then
    echo "  Patching $f ..."
    sed -i \
      's/from torchvision.transforms.functional_tensor import rgb_to_grayscale/from torchvision.transforms.functional import rgb_to_grayscale/' \
      "$f" || true
  fi
done

echo "=== [8] Patch animate.py (fp16 + torch.compile) ==="
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

tg_ok "[SadTalker] Установка завершена успешно ✅"
conda deactivate || true

# ═════════════════════════════════════════════════════════════════════════════
#  DEMUCS
# ═════════════════════════════════════════════════════════════════════════════
echo "=== [9] Setup demucs ==="
conda activate demucs
python -m pip install --upgrade pip --quiet

pip install torch==2.11.0 torchvision torchaudio \
  --index-url https://download.pytorch.org/whl/cu128 \
  --quiet \
  || { tg_error "[9] torch demucs" "Ошибка установки PyTorch в demucs"; exit 1; }

TORCH_VER=$(python -c "import torch; print(torch.__version__)")
echo "  torch: $TORCH_VER"

pip install "numpy<2.0" --quiet \
  || { tg_error "[9] numpy demucs" "Ошибка установки numpy<2.0 в demucs"; exit 1; }

pip install demucs soundfile --quiet \
  || { tg_error "[9] demucs install" "Ошибка установки demucs/soundfile"; exit 1; }

echo "=== [9.1] Verify demucs ==="
python -c "
import torch, numpy, demucs, soundfile
print('  torch:', torch.__version__)
print('  numpy:', numpy.__version__)
print('  CUDA:', torch.cuda.is_available())
print('  demucs OK | soundfile OK')
" || { tg_error "[9.1] verify demucs" "Проверка зависимостей demucs провалилась"; exit 1; }

tg_ok "[Demucs] Установка завершена успешно ✅"
conda deactivate || true

# ─────────────────────────────────────────────────────────────────────────────
echo "=== [10] Setup env vars ==="
if ! grep -q "/opt/miniconda3/bin/conda" /root/.bashrc 2>/dev/null; then
  /opt/miniconda3/bin/conda init bash || true
fi
if ! grep -q "PYTORCH_CUDA_ALLOC_CONF" /root/.bashrc 2>/dev/null; then
  echo 'export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True' >> /root/.bashrc
fi

# Снимаем глобальный trap — всё прошло успешно
trap - ERR

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== [DONE] Provisioning finished ==="
echo ""
echo "Структура:"
echo "  $PANDORA_DIR/"
echo "  ├── sadtalker/   (env: sadtalker / py3.10)"
echo "  │   ├── SadTalker/"
echo "  │   └── test/ (input, output, log)"
echo "  ├── demucs/      (env: demucs / py3.10)"
echo "  │   └── test/ (input, output, log)"
echo "  └── myproject/"
echo ""
echo "Вручную перенести:"
echo "  sadtalker_runner.py → $ST_DIR/"
echo "  test/* файлы        → $ST_DIR/test/"

tg_send "🎉 Провижнинг завершён полностью%0A%0A📁 ${PANDORA_DIR}%0A🐍 sadtalker: py3.10%0A🎵 demucs: py3.10%0A%0AВручную перенеси:%0A• sadtalker_runner.py → sadtalker/%0A• test/* → sadtalker/test/"
