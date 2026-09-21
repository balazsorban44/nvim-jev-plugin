#!/usr/bin/env node
// Render the README screenshots from a real Neovim.
//
// For each scene this spawns `nvim --embed`, attaches a 120x34 UI over
// msgpack-rpc, loads scripts/shot_init.lua (the plugin out of this repo, with a
// stubbed `jev.client.post` that answers from a table instead of the network),
// types the request into the panel like a user would, waits for the transcript
// line to appear, then paints the final cell grid — every cell's text and
// highlight exactly as Neovim sent it — into HTML and screenshots it with
// Chromium. Nothing is drawn by hand and no API call is made.
//
//   node scripts/screenshot.mjs            # all scenes into assets/
//   node scripts/screenshot.mjs 01 03      # only scenes whose name matches
//
// Env: JEV_NVIM (nvim binary), CHROMIUM_PATH (chromium executable).

import { spawn } from 'node:child_process';
import { writeSync } from 'node:fs';
import { mkdir, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { attach } from 'neovim';
import { chromium } from 'playwright-core';

const SCRIPTS = dirname(fileURLToPath(import.meta.url));
const REPO = dirname(SCRIPTS);
const OUT = join(REPO, 'assets');

const COLS = 120;
const ROWS = 34;
const FONT_SIZE = 14;
const LINE_HEIGHT = 19;
const SCALE = 1.75;

const NVIM = process.env.JEV_NVIM || 'nvim';
const CHROME = process.env.CHROMIUM_PATH || '/opt/pw-browsers/chromium';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
// The `neovim` client installs its own logger over console.*; write to fd 2.
const log = (...parts) => writeSync(2, `${parts.join(' ')}\n`);

// ---------------------------------------------------------------------------
// The cell grid, rebuilt from `redraw` events
// ---------------------------------------------------------------------------

class Screen {
  constructor(cols, rows) {
    this.cols = cols;
    this.rows = rows;
    this.defaults = { fg: 0xd0d0d0, bg: 0x14161b, sp: 0xd0d0d0 };
    this.attrs = new Map();
    this.cursor = { row: 0, col: 0 };
    this.busy = false;
    this.cells = Array.from({ length: rows }, () => this.blankRow());
  }

  blankRow() {
    return Array.from({ length: this.cols }, () => ({ text: ' ', hl: 0 }));
  }

  resize(cols, rows) {
    this.cols = cols;
    this.rows = rows;
    this.cells = Array.from({ length: rows }, () => this.blankRow());
  }

  clear() {
    this.cells = Array.from({ length: this.rows }, () => this.blankRow());
  }

  line(row, colStart, cells) {
    const target = this.cells[row];
    if (!target) return;
    let col = colStart;
    let hl = 0;
    for (const cell of cells) {
      const [text, hlId, repeat] = cell;
      if (hlId !== undefined && hlId !== null) hl = hlId;
      const times = repeat === undefined ? 1 : repeat;
      for (let i = 0; i < times; i += 1) {
        if (col >= this.cols) break;
        target[col] = { text, hl };
        col += 1;
      }
    }
  }

  scroll(top, bot, left, right, rows) {
    const move = (from, to) => {
      const src = this.cells[from];
      const dst = this.cells[to];
      if (!src || !dst) return;
      for (let c = left; c < right; c += 1) dst[c] = src[c];
    };
    if (rows > 0) {
      for (let r = top; r < bot - rows; r += 1) move(r + rows, r);
    } else if (rows < 0) {
      for (let r = bot - 1; r >= top - rows; r -= 1) move(r + rows, r);
    }
  }

  /** Resolved colours and decorations for a highlight id. */
  style(hl) {
    const a = this.attrs.get(hl) || {};
    let fg = a.foreground ?? this.defaults.fg;
    let bg = a.background ?? this.defaults.bg;
    if (a.reverse) [fg, bg] = [bg, fg];
    return {
      fg,
      bg,
      bold: !!a.bold,
      italic: !!a.italic,
      underline: !!(a.underline || a.undercurl || a.underdouble || a.underdotted || a.underdashed),
      strike: !!a.strikethrough,
    };
  }

  handle(events) {
    for (const event of events) {
      const [name, ...batches] = event;
      for (const args of batches) {
        switch (name) {
          case 'grid_resize':
            if (args[0] === 1) this.resize(args[1], args[2]);
            break;
          case 'default_colors_set':
            if (args[0] >= 0) this.defaults.fg = args[0];
            if (args[1] >= 0) this.defaults.bg = args[1];
            if (args[2] >= 0) this.defaults.sp = args[2];
            break;
          case 'hl_attr_define':
            this.attrs.set(args[0], args[1] || {});
            break;
          case 'grid_line':
            if (args[0] === 1) this.line(args[1], args[2], args[3]);
            break;
          case 'grid_clear':
            if (args[0] === 1) this.clear();
            break;
          case 'grid_scroll':
            if (args[0] === 1) this.scroll(args[1], args[2], args[3], args[4], args[5]);
            break;
          case 'grid_cursor_goto':
            if (args[0] === 1) this.cursor = { row: args[1], col: args[2] };
            break;
          case 'busy_start':
            this.busy = true;
            break;
          case 'busy_stop':
            this.busy = false;
            break;
          default:
            break;
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Grid -> HTML
// ---------------------------------------------------------------------------

const hex = (n) => `#${(n >>> 0).toString(16).padStart(6, '0').slice(-6)}`;
const escape = (s) =>
  s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

function css(style) {
  const parts = [`color:${hex(style.fg)}`, `background:${hex(style.bg)}`];
  if (style.bold) parts.push('font-weight:700');
  if (style.italic) parts.push('font-style:italic');
  if (style.underline) parts.push('text-decoration:underline');
  if (style.strike) parts.push('text-decoration:line-through');
  return parts.join(';');
}

function render(screen, title) {
  const rows = [];
  for (let r = 0; r < screen.rows; r += 1) {
    const cells = screen.cells[r] || screen.blankRow();
    const runs = [];
    let current = null;
    for (let c = 0; c < screen.cols; c += 1) {
      const cell = cells[c] || { text: ' ', hl: 0 };
      // The trailing half of a double-width character: already drawn.
      if (cell.text === '') continue;
      let style = screen.style(cell.hl);
      if (r === screen.cursor.row && c === screen.cursor.col) {
        style = { ...style, fg: style.bg, bg: screen.defaults.fg };
      }
      const key = css(style);
      if (!current || current.key !== key) {
        current = { key, text: '' };
        runs.push(current);
      }
      current.text += cell.text === ' ' ? ' ' : cell.text;
    }
    rows.push(
      `<div class="row">${runs
        .map((run) => `<span style="${run.key}">${escape(run.text)}</span>`)
        .join('')}</div>`
    );
  }

  return `<!doctype html>
<html><head><meta charset="utf-8"><title>${escape(title)}</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  html, body { margin: 0; padding: 0; background: #0a0b0f; }
  .page { display: inline-block; padding: 26px 30px 34px; background: #0a0b0f; }
  .frame {
    width: max-content;
    border-radius: 9px;
    overflow: hidden;
    box-shadow: 0 16px 44px rgba(0,0,0,.6), 0 0 0 1px rgba(255,255,255,.08);
  }
  .bar {
    position: relative;
    height: 30px;
    background: #23262e;
    display: flex;
    align-items: center;
    padding: 0 11px;
    gap: 7px;
  }
  .dot { width: 10px; height: 10px; border-radius: 50%; }
  .title {
    position: absolute; left: 0; right: 0; text-align: center;
    font: 500 11.5px/1 -apple-system, "DejaVu Sans", sans-serif;
    color: #9aa2b4; letter-spacing: .02em; pointer-events: none;
  }
  .term { padding: 9px 11px; background: ${hex(screen.defaults.bg)}; }
  .row {
    font-family: "DejaVu Sans Mono", "Liberation Mono", monospace;
    font-size: ${FONT_SIZE}px;
    line-height: ${LINE_HEIGHT}px;
    height: ${LINE_HEIGHT}px;
    white-space: pre;
    font-variant-ligatures: none;
    font-feature-settings: "liga" 0, "calt" 0;
  }
  .row span { display: inline; }
</style></head>
<body><div class="page"><div class="frame">
  <div class="bar">
    <span class="dot" style="background:#ff5f57"></span>
    <span class="dot" style="background:#febc2e"></span>
    <span class="dot" style="background:#28c840"></span>
    <span class="title">${escape(title)}</span>
  </div>
  <div class="term">${rows.join('')}</div>
</div></div></body></html>`;
}

// ---------------------------------------------------------------------------
// One Neovim, driven over msgpack-rpc
// ---------------------------------------------------------------------------

async function startNvim() {
  const proc = spawn(
    NVIM,
    ['--embed', '--clean', '-u', 'NONE', '-i', 'NONE', '--cmd', `set rtp^=${REPO}`],
    { cwd: REPO, stdio: ['pipe', 'pipe', 'inherit'], env: { ...process.env, NVIM_LOG_FILE: '/dev/null' } }
  );
  // nvim is killed while requests may still be in flight.
  proc.stdin.on('error', () => {});
  proc.on('error', () => {});
  const nvim = attach({ proc });
  const screen = new Screen(COLS, ROWS);
  nvim.on('notification', (method, args) => {
    if (method === 'redraw') screen.handle(args);
  });
  await nvim.request('nvim_ui_attach', [COLS, ROWS, { ext_linegrid: true, rgb: true }]);
  await nvim.request('nvim_exec_lua', [
    `return loadfile(...)()`,
    [join(SCRIPTS, 'shot_init.lua')],
  ]);

  const api = {
    nvim,
    screen,
    proc,
    lua: (code, args = []) => nvim.request('nvim_exec_lua', [code, args]),
    input: (keys) => nvim.request('nvim_input', [keys]),
    async lines() {
      return nvim.request('nvim_exec_lua', ['return _G.JevShot.lines()', []]);
    },
    /** Type a request on the panel's prompt line and press <CR>. */
    async ask(text) {
      await api.input('<Esc>i');
      await api.input(text);
      await sleep(40);
      await api.input('<CR>');
    },
    /** Poll the transcript until a line contains `needle`. */
    async waitForLine(needle, timeout = 5000) {
      const until = Date.now() + timeout;
      for (;;) {
        let lines = [];
        try {
          lines = await Promise.race([api.lines(), sleep(400).then(() => null)]);
        } catch {
          lines = null;
        }
        if (lines && lines.some((line) => line.includes(needle))) return lines;
        if (Date.now() > until) {
          throw new Error(`timed out waiting for transcript line ${JSON.stringify(needle)}`);
        }
        await sleep(60);
      }
    },
    async settle(ms = 350) {
      await nvim.request('nvim_eval', ['1']).catch(() => {});
      await sleep(ms);
    },
    quit() {
      // `qall!` never answers — nvim is gone before it can — so just end it.
      proc.kill('SIGTERM');
    },
  };
  return api;
}

// ---------------------------------------------------------------------------
// The scenes
// ---------------------------------------------------------------------------

const scenes = [
  {
    name: '01-split',
    title: 'nvim  —  jev.nvim',
    async run(d) {
      await d.lua(`_G.JevShot.edit('lua/jev/policy.lua', 46)`);
      await d.input(':Jev<CR>');
      await sleep(250);
      await d.ask('split the window vertically');
      await d.waitForLine('ok: vertical split');
      await d.settle();
    },
  },
  {
    name: '02-goto-line',
    title: 'nvim  —  jev.nvim',
    async run(d) {
      await d.lua(`_G.JevShot.edit('lua/jev/actions.lua', 1)`);
      await d.input(':Jev<CR>');
      await sleep(250);
      await d.ask('go to line 40');
      await d.waitForLine('ok: line 40');
      await d.settle();
    },
  },
  {
    name: '03-confirm',
    title: 'nvim  —  jev.nvim',
    async run(d) {
      await d.lua(`_G.JevShot.edit('lua/jev/panel.lua', 60)`);
      // `inputlist()` prints from the last screen row upward, so the confirm
      // prompt always scrolls the screen a few lines — that is what a terminal
      // shows too. Open the panel without typing `:Jev` so no command echo is
      // left behind in the message area.
      await d.lua(`vim.cmd('Jev')`);
      await sleep(250);
      await d.ask('throw away my changes and reload the file');
      // The confirm tier hands over to vim.ui.select, which blocks on input:
      // capture the screen while it is still waiting, then cancel.
      await d.waitForLine('reload_file', 5000).catch(() => {});
      await sleep(900);
    },
    async after(d) {
      await d.input('2<CR>');
      await sleep(200);
    },
  },
  {
    name: '04-none',
    title: 'nvim  —  jev.nvim',
    async run(d) {
      await d.lua(`_G.JevShot.edit('lua/jev/init.lua', 150)`);
      await d.input(':Jev<CR>');
      await sleep(250);
      await d.ask('go to line 40');
      await d.waitForLine('ok: line 40');
      await d.ask('use relative line numbers');
      await d.waitForLine('relativenumber on');
      await d.ask('make me a sandwich');
      await d.waitForLine('no confident match');
      await d.settle();
    },
  },
];

// ---------------------------------------------------------------------------

async function main() {
  const wanted = process.argv.slice(2);
  const todo = wanted.length
    ? scenes.filter((s) => wanted.some((w) => s.name.includes(w)))
    : scenes;
  if (!todo.length) {
    log(`no scene matches ${wanted.join(', ')}`);
    process.exit(1);
  }

  await mkdir(OUT, { recursive: true });
  const browser = await chromium.launch({
    executablePath: CHROME,
    args: ['--no-sandbox', '--disable-dev-shm-usage', '--font-render-hinting=none'],
  });
  const page = await browser.newPage({
    viewport: { width: 1400, height: 900 },
    deviceScaleFactor: SCALE,
  });

  for (const scene of todo) {
    log(`${scene.name} …`);
    const d = await startNvim();
    try {
      await scene.run(d);
      const html = render(d.screen, scene.title);
      // The intermediate page, for debugging a scene that came out wrong.
      if (process.env.JEV_SHOT_HTML) await writeFile(join(OUT, `${scene.name}.html`), html);
      await page.setContent(html, { waitUntil: 'load' });
      await page.evaluate(() => document.fonts.ready.then(() => true));
      const out = join(OUT, `${scene.name}.png`);
      await page.locator('.page').screenshot({ path: out, scale: 'device' });
      if (scene.after) await scene.after(d);
      log(`  → assets/${scene.name}.png`);
    } finally {
      d.quit();
    }
  }

  await browser.close();
}

main().then(
  () => process.exit(0),
  (err) => {
    log(err && err.stack ? err.stack : String(err));
    process.exit(1);
  }
);
