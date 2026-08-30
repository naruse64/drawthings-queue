# 手元固有の設定。config.local.sh にコピーして使う。
#
#   cp config.example.sh config.local.sh
#
# config.local.sh は git 管理外なので、個人の設定がリポジトリに乗らない。
# 変更したら bin/dtq-setup を再実行して配置し直すこと。

# 使用するモデル。Draw Things のモデルディレクトリにあるファイル名で指定する。
# DT_MODEL="z_image_turbo_1.0_q8p.ckpt"

# 使用を許可する LoRA。ここに無いものはジョブ検証の段階で弾かれる。
# DT_LORAS=(
#   "realisticsnapshotz_image_turbo_lora_f16.ckpt"
# )

# モデル本体以外に generate が要求するファイル。
# 別のモデルに変えると必要なものも変わる。不足があれば
# draw-things-cli がファイル名を挙げて教えてくれるので、それを見て足す。
# DT_MODEL_DEPS=(
#   "qwen_3_vl_4b_instruct_q8p.ckpt"
#   "qwen_3_vl_4b_instruct_q8p.ckpt-tensordata"
#   "flux_1_vae_f16.ckpt"
#   "custom.json"
#   "custom_lora.json"
#   "custom_prompt_style.json"
# )

# 画像の保存先を変えたい場合。
# DTQ_IMAGES_DIR="$HOME/DrawThings"
