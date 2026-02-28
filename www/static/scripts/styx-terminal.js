/**
 * <styx-terminal> — Typing animation Web Component for StyxOS
 *
 * Usage:
 *   <styx-terminal
 *     speed="65"
 *     pause="1800"
 *     theme="dark"
 *     commands='[
 *       {"prompt":"styx #","cmd":"zish --version","output":"zish 0.4.2-dev (zig 0.14.1, musl 1.2.5)"},
 *       {"prompt":"styx #","cmd":"zish"},
 *       {"prompt":"zish»","cmd":"query SELECT * FROM history WHERE command LIKE \u0027ps%\u0027","output":" 142 | ps aux\n 287 | ps aux | grep zigbee\n 301 | pstree -p"},
 *       {"prompt":"zish»","cmd":"help","output":" builtins: cd, query, alias, export, set, history, jobs, exit\n type \u0027help <cmd>\u0027 for details"},
 *       {"prompt":"zish»","cmd":"exit"}
 *     ]'
 *   ></styx-terminal>
 *
 * Attributes:
 *   speed     — base typing speed in ms (default: 65)
 *   jitter    — random extra ms per keystroke (default: 50)
 *   pause     — pause after typed command in ms (default: 1800)
 *   restart   — pause before loop restart in ms (default: 2500)
 *   theme     — "dark" (default) or "light"
 *   title     — titlebar text (default: "zish — styx")
 *   commands  — JSON array of {prompt, cmd, output?} objects
 *   no-chrome — if present, hides the titlebar/window chrome
 */

class StyxTerminal extends HTMLElement {

  static get observedAttributes() {
    return ['speed', 'jitter', 'pause', 'restart', 'theme', 'title', 'commands', 'no-chrome'];
  }

  constructor() {
    super();
    this.attachShadow({ mode: 'open' });
    this._running = false;
    this._abortCtrl = null;
  }

  // ── Defaults ────────────────────────────────────────────
  get _config() {
    return {
      speed:    parseInt(this.getAttribute('speed'))   || 65,
      jitter:   parseInt(this.getAttribute('jitter'))  || 50,
      pause:    parseInt(this.getAttribute('pause'))   || 1800,
      restart:  parseInt(this.getAttribute('restart')) || 2500,
      pauseBefore: 500,
      outputDelay: 300,
      deleteSpeed: 18,
    };
  }

  get _title() {
    return this.getAttribute('title') || 'zish — styx';
  }

  get _theme() {
    return this.getAttribute('theme') || 'dark';
  }

  get _noChrome() {
    return this.hasAttribute('no-chrome');
  }

  get _commands() {
    const defaultCmds = [
      { prompt: 'styx #', cmd: 'zish --version', output: 'zish 0.4.2-dev (zig 0.14.1, musl 1.2.5)' },
      { prompt: 'styx #', cmd: 'zish' },
      { prompt: 'zish»',  cmd: "query SELECT * FROM history WHERE command LIKE 'ps%'", output: ' 142 | ps aux\n 287 | ps aux | grep zigbee\n 301 | pstree -p' },
      { prompt: 'zish»',  cmd: 'help', output: ' builtins: cd, query, alias, export, set, history, jobs, exit\n type \'help <cmd>\' for details' },
      { prompt: 'zish»',  cmd: 'exit' },
    ];
    try {
      const attr = this.getAttribute('commands');
      return attr ? JSON.parse(attr) : defaultCmds;
    } catch {
      console.warn('<styx-terminal> invalid commands JSON, using defaults');
      return defaultCmds;
    }
  }

  // ── Lifecycle ───────────────────────────────────────────
  connectedCallback() {
    this._render();
    this._start();
  }

  disconnectedCallback() {
    this._stop();
  }

  attributeChangedCallback() {
    if (this.shadowRoot.querySelector('.terminal')) {
      this._stop();
      this._render();
      this._start();
    }
  }

  // ── Render ──────────────────────────────────────────────
  _render() {
    const isDark = this._theme === 'dark';

    const colors = isDark ? {
      bg:       '#12121a',
      titleBg:  '#1a1a26',
      border:   'rgba(255,255,255,0.05)',
      shadow:   '0 0 0 1px rgba(255,255,255,0.06), 0 20px 60px rgba(0,0,0,0.6), 0 0 80px rgba(90,120,200,0.08)',
      titleCol: '#555',
      prompt:   '#6ee7b7',
      text:     '#d4d4e8',
      output:   '#888a9e',
      cursor:   '#6ee7b7',
    } : {
      bg:       '#f7f7f5',
      titleBg:  '#e8e8e4',
      border:   'rgba(0,0,0,0.08)',
      shadow:   '0 0 0 1px rgba(0,0,0,0.08), 0 12px 40px rgba(0,0,0,0.1)',
      titleCol: '#999',
      prompt:   '#16794a',
      text:     '#2a2a3a',
      output:   '#6e6e82',
      cursor:   '#16794a',
    };

    const chromeHTML = this._noChrome ? '' : `
      <div class="titlebar">
        <div class="dot red"></div>
        <div class="dot yellow"></div>
        <div class="dot green"></div>
        <div class="title-text">${this._esc(this._title)}</div>
      </div>`;

    this.shadowRoot.innerHTML = `
      <style>
        :host {
          display: block;
          font-family: 'JetBrains Mono', 'Fira Code', 'SF Mono', 'Cascadia Code', 'Consolas', monospace;
          font-size: 14px;
        }
        .terminal {
          background: ${colors.bg};
          border-radius: ${this._noChrome ? '6px' : '10px'};
          overflow: hidden;
          box-shadow: ${colors.shadow};
        }
        .titlebar {
          display: flex;
          align-items: center;
          gap: 8px;
          padding: 12px 16px;
          background: ${colors.titleBg};
          border-bottom: 1px solid ${colors.border};
        }
        .dot {
          width: 12px; height: 12px; border-radius: 50%;
        }
        .dot.red    { background: #ff5f57; }
        .dot.yellow { background: #febc2e; }
        .dot.green  { background: #28c840; }
        .title-text {
          flex: 1;
          text-align: center;
          color: ${colors.titleCol};
          font-size: 12px;
          letter-spacing: 0.5px;
        }
        .body {
          padding: 20px 22px 28px;
          min-height: 180px;
          line-height: 1.7;
        }
        .history-line {
          white-space: pre-wrap;
          word-break: break-all;
        }
        .history-line .prompt { color: ${colors.prompt}; font-weight: 700; }
        .history-line .text   { color: ${colors.text}; }
        .history-line .output { color: ${colors.output}; }
        .active-line { white-space: pre; }
        .active-line .prompt { color: ${colors.prompt}; font-weight: 700; }
        .active-line .cmd    { color: ${colors.text}; }
        .cursor {
          display: inline-block;
          width: 0.55em;
          height: 1.15em;
          background: ${colors.cursor};
          vertical-align: text-bottom;
          margin-left: 1px;
          animation: blink 1s step-end infinite;
        }
        .cursor.typing { animation: none; opacity: 1; }
        @keyframes blink { 50% { opacity: 0; } }
      </style>
      <div class="terminal">
        ${chromeHTML}
        <div class="body">
          <div class="active-line">
            <span class="prompt">styx #</span> <span class="cmd"></span><span class="cursor"></span>
          </div>
        </div>
      </div>`;
  }

  // ── Animation engine ────────────────────────────────────
  _start() {
    this._abortCtrl = new AbortController();
    this._running = true;
    this._run(this._abortCtrl.signal);
  }

  _stop() {
    this._running = false;
    if (this._abortCtrl) this._abortCtrl.abort();
  }

  _sleep(ms, signal) {
    return new Promise((resolve, reject) => {
      const id = setTimeout(resolve, ms);
      if (signal) signal.addEventListener('abort', () => { clearTimeout(id); reject(new DOMException('Aborted', 'AbortError')); }, { once: true });
    });
  }

  async _run(signal) {
    const root   = this.shadowRoot;
    const bodyEl = root.querySelector('.body');
    const active = root.querySelector('.active-line');
    const promptEl = active.querySelector('.prompt');
    const cmdEl    = active.querySelector('.cmd');
    const cursorEl = active.querySelector('.cursor');
    const cfg = this._config;

    const pushHistory = (prompt, text, output) => {
      const div = document.createElement('div');
      div.className = 'history-line';
      let html = `<span class="prompt">${this._esc(prompt)}</span> <span class="text">${this._esc(text)}</span>`;
      if (output) html += `\n<span class="output">${this._esc(output)}</span>`;
      div.innerHTML = html;
      bodyEl.insertBefore(div, active);
    };

    const clearHistory = () => {
      root.querySelectorAll('.history-line').forEach(el => el.remove());
    };

    const typeText = async (text) => {
      cursorEl.classList.add('typing');
      for (const ch of text) {
        cmdEl.textContent += ch;
        await this._sleep(cfg.speed + Math.random() * cfg.jitter, signal);
      }
      cursorEl.classList.remove('typing');
    };

    try {
      while (this._running) {
        const commands = this._commands;
        for (const step of commands) {
          promptEl.textContent = step.prompt;
          cmdEl.textContent = '';

          await this._sleep(cfg.pauseBefore, signal);
          await typeText(step.cmd);
          await this._sleep(cfg.pause, signal);

          // "Execute" — move to history
          pushHistory(step.prompt, step.cmd, null);
          cmdEl.textContent = '';

          if (step.output) {
            await this._sleep(cfg.outputDelay, signal);
            const outDiv = document.createElement('div');
            outDiv.className = 'history-line';
            outDiv.innerHTML = `<span class="output">${this._esc(step.output)}</span>`;
            bodyEl.insertBefore(outDiv, active);
          }
        }

        await this._sleep(cfg.restart, signal);
        clearHistory();
        promptEl.textContent = 'styx #';
        cmdEl.textContent = '';
      }
    } catch (e) {
      if (e.name !== 'AbortError') throw e;
    }
  }

  _esc(s) {
    return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }
}

customElements.define('styx-terminal', StyxTerminal);
