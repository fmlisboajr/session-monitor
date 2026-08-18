#!/bin/zsh
# Session Monitor - instalador para macOS
# Equivalente ao install.ps1 (Windows), adaptado para macOS:
#   - copia os arquivos para ~/.claude/dashboard/
#   - troca o openTerminal (wt.exe/PowerShell) por Terminal.app
#   - instala um LaunchAgent que sobe o servidor no login
#   - cria o comando global `session-monitor`
set -e

SRC="${0:A:h}"
DEST="$HOME/.claude/dashboard"
BIN="$HOME/.local/bin"
AGENT_LABEL="com.session-monitor.dashboard"
PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"

echo ""
echo "  Instalando Session Monitor (macOS)..."

# 1. Copia arquivos
mkdir -p "$DEST" "$BIN" "$HOME/Library/LaunchAgents"
cp "$SRC/server.js"      "$DEST/server.js"
cp "$SRC/dashboard.html" "$DEST/dashboard.html"
cp "$SRC/version.json"   "$DEST/version.json"
echo "  [OK] Arquivos copiados para $DEST"

# 2. Patch macOS: openTerminal usa Terminal.app em vez de wt.exe + PowerShell.
#    Reaplicado a cada instalacao, entao sobrevive a um `git pull` do upstream.
python3 - "$DEST/server.js" <<'PATCH'
import re, sys
p = sys.argv[1]
src = open(p, encoding='utf-8').read()

novo = '''// --- macOS: abre uma janela do Terminal.app (equivalente ao wt.exe do Windows) ---
// Usa arquivo temporario + `source` para evitar quoting quebrado e para que o
// comando rode no shell interativo do usuario (PATH correto, janela permanece
// aberta depois que o claude sai, igual ao -NoExit do PowerShell).
function openTerminal(cwd, claudeArgs) {
  const shPath = path.join(os.tmpdir(), `claude_session_${Date.now()}.sh`);
  fs.writeFileSync(shPath, `cd ${JSON.stringify(cwd)}\\nclaude ${claudeArgs}\\n`, 'utf8');
  try {
    execSync(
      `osascript -e 'tell application "Terminal" to do script "source ${shPath}"' ` +
      `-e 'tell application "Terminal" to activate'`
    );
  } catch (e) {
    // Fallback sem AppleScript (caso a permissao de Automacao seja negada).
    fs.chmodSync(shPath, 0o755);
    fs.writeFileSync(shPath, `#!/bin/zsh -l\\ncd ${JSON.stringify(cwd)}\\nclaude ${claudeArgs}\\nexec zsh -i\\n`, 'utf8');
    execSync(`open -a Terminal ${JSON.stringify(shPath)}`);
  }
}'''

# Substitui a funcao openTerminal original (do "function openTerminal" ate a chave que fecha).
m = re.search(r'^function openTerminal\(cwd, claudeArgs\) \{.*?^\}', src, re.S | re.M)
if not m:
    if 'macOS: abre uma janela do Terminal.app' in src:
        print('  [OK] Patch macOS ja aplicado')
        sys.exit(0)
    print('  [ERRO] openTerminal nao encontrado em server.js - patch NAO aplicado')
    sys.exit(1)
src = src[:m.start()] + novo + src[m.end():]

# Remove o comentario Windows que ficava logo acima da funcao.
src = re.sub(r'^// ─── Abre no Windows Terminal.*?\n(?:^// ─── que a usu.*?\n)?', '', src, flags=re.M)

open(p, 'w', encoding='utf-8').write(src)
print('  [OK] Patch macOS aplicado (Terminal.app no lugar de wt.exe)')
PATCH

# 3. Wrapper que resolve o node (nvm/homebrew) na hora de subir o servidor
cat > "$DEST/run-server.sh" <<'RUNNER'
#!/bin/zsh
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
if [ -s "$HOME/.nvm/nvm.sh" ]; then
  export NVM_DIR="$HOME/.nvm"
  . "$NVM_DIR/nvm.sh" >/dev/null 2>&1
fi
exec node "$HOME/.claude/dashboard/server.js"
RUNNER
chmod +x "$DEST/run-server.sh"

# 4. LaunchAgent: sobe no login e mantem de pe (nao abre navegador sozinho)
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$AGENT_LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$DEST/run-server.sh</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$DEST/server.log</string>
  <key>StandardErrorPath</key><string>$DEST/server.log</string>
</dict>
</plist>
PLISTEOF
launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "  [OK] LaunchAgent instalado (sobe no login)"

# 5. Comando global
cat > "$BIN/session-monitor" <<'CLIEOF'
#!/bin/zsh
AGENT="com.session-monitor.dashboard"
DEST="$HOME/.claude/dashboard"
case "${1:-open}" in
  open)    open "http://localhost:4242" ;;
  start)   launchctl kickstart -k "gui/$(id -u)/$AGENT" && echo "servidor iniciado" ;;
  stop)    launchctl bootout "gui/$(id -u)/$AGENT" && echo "servidor parado" ;;
  restart) launchctl kickstart -k "gui/$(id -u)/$AGENT" && echo "servidor reiniciado" ;;
  status)  launchctl print "gui/$(id -u)/$AGENT" 2>/dev/null | grep -E "state|pid" || echo "agente nao carregado"
           lsof -nP -iTCP:4242 -sTCP:LISTEN 2>/dev/null | tail -n +2 || echo "porta 4242 livre" ;;
  logs)    tail -n 50 -f "$DEST/server.log" ;;
  *) echo "uso: session-monitor [open|start|stop|restart|status|logs]" ;;
esac
CLIEOF
chmod +x "$BIN/session-monitor"
echo "  [OK] Comando global: session-monitor"

echo ""
echo "  Pronto! Dashboard em http://localhost:4242"
echo ""
