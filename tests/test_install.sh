#!/bin/sh
# Regression tests for install.sh: verify that fresh install creates config.toml
# and update preserves an existing config.toml (features, models, provider).
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

setup_test_env() {
  TEST_DIR="$(mktemp -d)"
  BIN_DIR="$TEST_DIR/bin"
  HOME_DIR="$TEST_DIR/home"
  WEB_DIR="$TEST_DIR/web"
  mkdir -p "$BIN_DIR" "$HOME_DIR" "$WEB_DIR/skills/compress"

  # Stub rg to avoid triggering distro package manager sudo prompts
  touch "$BIN_DIR/rg" && chmod +x "$BIN_DIR/rg"

  # Stub byteask-engine & release marker to satisfy skip-if-current
  printf '\177ELF' > "$BIN_DIR/byteask-engine"
  dd if=/dev/zero bs=1M count=20 >> "$BIN_DIR/byteask-engine" 2>/dev/null
  chmod +x "$BIN_DIR/byteask-engine"

  _os="$(uname -s 2>/dev/null || echo linux)"
  _arch="$(uname -m 2>/dev/null || echo x86_64)"
  case "$_os" in
    Linux)  _os=linux ;;
    Darwin) _os=darwin ;;
  esac
  case "$_arch" in
    x86_64|amd64)   _arch=x86_64 ;;
    aarch64|arm64)  _arch=arm64 ;;
  esac
  _asset="byteask-engine-$_os-$_arch.zst"
  _sha="0000000000000000000000000000000000000000000000000000000000000000"
  printf 'asset=%s\nsha256=%s\n' "$_asset" "$_sha" > "$BIN_DIR/.engine-release"
  printf '%s  %s\n' "$_sha" "$_asset" > "$WEB_DIR/SHA256SUMS"
  printf '#!/bin/sh\necho "byteask 0.2.4"\n' > "$WEB_DIR/byteask"
  chmod +x "$WEB_DIR/byteask"
  printf '{"models": ["gpt-5.4"]}\n' > "$WEB_DIR/models-catalog.json"
  printf 'def clamp_effort(): pass\n' > "$WEB_DIR/effort.py"
  printf 'name: compress\n' > "$WEB_DIR/skills/compress/SKILL.md"
}

cleanup_test_env() {
  rm -rf "$TEST_DIR"
}

run_installer() {
  ENGINE_URL="file://$WEB_DIR" BUNDLE_URL="file://$WEB_DIR" GATEWAY_URL="file://$WEB_DIR" \
    BYTEASK_NO_TELEMETRY=1 PATH="$BIN_DIR:$PATH" PREFIX="$BIN_DIR" BYTEASK_HOME="$HOME_DIR" \
    sh "$REPO_ROOT/install.sh" >/dev/null 2>&1
}

test_fresh_install() {
  setup_test_env
  run_installer

  [ -f "$HOME_DIR/config.toml" ] || { echo "FAIL: config.toml not created on fresh install" >&2; return 1; }
  grep -q '^model = "auto"' "$HOME_DIR/config.toml" || { echo "FAIL: default model missing" >&2; return 1; }
  grep -q '^model_provider = "byteask"' "$HOME_DIR/config.toml" || { echo "FAIL: default provider missing" >&2; return 1; }
  cleanup_test_env
  echo "test_fresh_install: PASS"
}

test_update_preserves_config() {
  setup_test_env
  cat > "$HOME_DIR/config.toml" <<'EOF'
model = "claude-3-7-sonnet"
model_provider = "byok-local"
web_search = "live"

[features]
plugins = true
commit_attribution = false

[model_providers.byok-local]
name = "ByteAsk (your key)"
base_url = "http://127.0.0.1:8799/byteask/v1"
wire_api = "responses"
requires_openai_auth = false
supports_websockets = false

[model_providers.byok-local.http_headers]
X-BYOK-Token = "secret123"
x-openai-actor-authorization = "byteask"
EOF

  run_installer

  grep -q '^model = "claude-3-7-sonnet"' "$HOME_DIR/config.toml" \
    || { echo "FAIL: custom model was overwritten on update" >&2; return 1; }
  grep -q '^model_provider = "byok-local"' "$HOME_DIR/config.toml" \
    || { echo "FAIL: model_provider was clobbered on update" >&2; return 1; }
  grep -q '\[features\]' "$HOME_DIR/config.toml" \
    || { echo "FAIL: [features] table was wiped on update" >&2; return 1; }
  grep -q '^plugins = true' "$HOME_DIR/config.toml" \
    || { echo "FAIL: features.plugins was wiped on update" >&2; return 1; }
  grep -q '^commit_attribution = false' "$HOME_DIR/config.toml" \
    || { echo "FAIL: features.commit_attribution was wiped on update" >&2; return 1; }
  grep -q '^X-BYOK-Token = "secret123"' "$HOME_DIR/config.toml" \
    || { echo "FAIL: byok-local headers were wiped on update" >&2; return 1; }

  cleanup_test_env
  echo "test_update_preserves_config: PASS"
}

test_update_adds_catalog_if_missing() {
  setup_test_env
  cat > "$HOME_DIR/config.toml" <<'EOF'
model = "gpt-5.4"
model_provider = "byteask"

[model_providers.byteask]
name = "ByteAsk"
EOF

  run_installer

  grep -q '^model_catalog_json = ' "$HOME_DIR/config.toml" \
    || { echo "FAIL: model_catalog_json was not added to config lacking it" >&2; return 1; }

  cleanup_test_env
  echo "test_update_adds_catalog_if_missing: PASS"
}

test_fresh_install
test_update_preserves_config
test_update_adds_catalog_if_missing
echo "All tests passed."
