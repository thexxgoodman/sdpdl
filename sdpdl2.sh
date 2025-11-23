#!/bin/bash
# Provisioning script for Vast.ai
# Miniconda + envs: sadtalker (py3.10), pandorapdl (py3.12)
# Структура:
#   /workspace/PandoraPDL
#   /workspace/PandoraPDL/SadTalker

set -eo pipefail

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
# Подключаем conda к текущей shell
eval "$(/opt/miniconda3/bin/conda shell.bash hook)"

echo "=== [2.1] Accept Anaconda Terms of Service for defaults (non-interactive) ==="
# На новых версиях conda может быть плагин tos, который ломает CI/скрипты.
# Если подкоманда 'conda tos' существует – принимаем ToS для канала defaults.
if conda help tos >/dev/null 2>&1; then
  echo "Found 'conda tos' plugin, accepting TOS for channel 'defaults'..."
  # Рекомендованный способ для CI: conda tos accept --override-channels --channel defaults
  conda tos accept --override-channels --channel defaults || true
else
  echo "'conda tos' subcommand not available (probably older conda); skipping TOS accept."
fi

echo "=== [3] Create envs 'sadtalker' (py3.10) and 'pandorapdl' (py3.12) ==="

# Создаём окружение 'sadtalker', если его ещё нет
if ! conda env list | grep -qE '^sadtalker[[:space:]]'; then
  echo "Creating conda env 'sadtalker' with python=3.10..."
  conda create -y -n sadtalker python=3.10
else
  echo "Conda env 'sadtalker' already exists, skipping create."
fi

# Создаём окружение 'pandorapdl', если его ещё нет
if ! conda env list | grep -qE '^pandorapdl[[:space:]]'; then
  echo "Creating conda env 'pandorapdl' with python=3.12..."
  conda create -y -n pandorapdl python=3.12
else
  echo "Conda env 'pandorapdl' already exists, skipping create."
fi

echo "=== [3.1] Activate 'sadtalker' env for SadTalker setup ==="
# Дальше вся установка SadTalker идёт в env 'sadtalker'
conda activate sadtalker

# Обновляем pip (по желанию можно убрать)
python -m pip install --upgrade pip

echo "=== [4] Ensure git + ffmpeg installed ==="
if ! command -v git >/dev/null 2>&1 || ! command -v ffmpeg >/dev/null 2>&1; then
  # В образах Vast обычно есть apt, но на всякий случай без ошибок, если его нет
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y git ffmpeg
    apt-get clean
  else
    echo "apt-get not available, assume git/ffmpeg already present or install manually."
  fi
fi

echo "=== [5] Clone or update SadTalker in $PROJECT_DIR/SadTalker ==="
if [ ! -d "$PROJECT_DIR/SadTalker/.git" ]; then
  echo "Cloning SadTalker..."
  git clone https://github.com/OpenTalker/SadTalker.git "$PROJECT_DIR/SadTalker"
else
  echo "SadTalker already exists, pulling latest..."
  cd "$PROJECT_DIR/SadTalker"
  git pull --rebase || true
fi

cd "$PROJECT_DIR/SadTalker"

echo "=== [6] Install SadTalker requirements into conda env 'sadtalker' ==="
pip install -r requirements.txt

echo "=== [7] Download SadTalker models ==="
bash scripts/download_models.sh

echo "=== [8] Fix basicsr rgb_to_grayscale import (if needed) ==="
BASICS_PATH=$(python - << 'EOF'
import basicsr, inspect, os
path = os.path.join(os.path.dirname(inspect.getfile(basicsr)), "data", "degradations.py")
print(path)
EOF
)

if [ -f "$BASICS_PATH" ]; then
  echo "Patching $BASICS_PATH ..."
  sed -i 's/from torchvision.transforms.functional_tensor import rgb_to_grayscale/from torchvision.transforms.functional import rgb_to_grayscale/' "$BASICS_PATH" || true
else
  echo "WARNING: basicsr degradations.py not found, skip patch."
fi

echo "=== [9] Setup conda for future shells (without auto-activation) ==="
# Добавляем только conda init в .bashrc root'а, без "conda activate ..."
if ! grep -q "/opt/miniconda3/bin/conda" /root/.bashrc 2>/dev/null; then
  /opt/miniconda3/bin/conda init bash || true
fi

# Явно деактивируем окружение в конце скрипта
conda deactivate || true

echo "=== [DONE] Provisioning finished ==="
echo "Project dir: $PROJECT_DIR"
echo "SadTalker:   $PROJECT_DIR/SadTalker"
echo "Envs:        sadtalker (py3.10), pandorapdl (py3.12)"
