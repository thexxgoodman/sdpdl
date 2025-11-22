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

echo "=== [2] Init conda in bash and create envs 'sadtalker' (py3.10) and 'pandorapdl' (py3.12) ==="

# Подключаем conda к текущей shell
eval "$(/opt/miniconda3/bin/conda shell.bash hook)"

# --- ВАЖНО: авто-акцепт ToS для Anaconda-каналов (фикс CondaToSNonInteractiveError) ---
# Если плагин TOS есть — эти команды примут условия.
# Если плагина нет — вернётся ошибка, но мы её игнорируем (|| true).
export CONDA_PLUGINS_AUTO_ACCEPT_TOS=true

echo "=== [2.0] Accept Conda Terms of Service (if required) ==="
conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main || true
conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r    || true
# --- конец блока TOS ---

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

echo "=== [2.1] Activate 'sadtalker' env for SadTalker setup ==="
# Дальше вся установка SadTalker идёт в env 'sadtalker'
conda activate sadtalker

# Обновляем pip (по желанию можно убрать)
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
pip install -r requirements.txt

echo "=== [6] Download SadTalker models ==="
bash scripts/download_models.sh

echo "=== [7] Fix basicsr rgb_to_grayscale import (if needed) ==="
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

echo "=== [8] Setup conda for future shells (without auto-activation) ==="
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
