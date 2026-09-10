#!/usr/bin/env node
/**
 * Playwright browser driver daemon for Rail QA harness.
 * Listens on a Unix domain socket and provides HTTP IPC endpoints for driving the app.
 */
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { chromium } from 'playwright';

const args = process.argv.slice(2);
function getArg(flag, defaultValue = null) {
  const idx = args.indexOf(flag);
  return idx !== -1 && idx + 1 < args.length ? args[idx + 1] : defaultValue;
}
const hasFlag = (flag) => args.includes(flag);

const sessionDir = getArg('--session') || process.env.AXIS_QA_DIR || '/tmp/rail-qa/default';
const initialUrl = getArg('--url') || 'http://127.0.0.1:4002/dev/login';
const foreground = hasFlag('--foreground');
const socketPath = path.join(sessionDir, 'driver.sock');

fs.mkdirSync(sessionDir, { recursive: true });
if (fs.existsSync(socketPath)) {
  fs.unlinkSync(socketPath);
}

const consoleLogs = [];
const exceptions = [];

console.log(`[driver] Launching Chrome (foreground: ${foreground})...`);
const browser = await chromium.launch({
  channel: 'chrome',
  headless: !foreground,
  args: ['--no-first-run', '--no-default-browser-check']
});

const context = await browser.newContext({
  viewport: { width: 1800, height: 1130 },
  deviceScaleFactor: 1
});

const page = await context.newPage();

page.on('console', (msg) => {
  const entry = `[${msg.type()}] ${msg.text()}`;
  consoleLogs.push(entry);
  if (consoleLogs.length > 500) consoleLogs.shift();
  if (msg.type() === 'error') {
    exceptions.push(entry);
  }
});

page.on('pageerror', (err) => {
  const entry = `[PAGE ERROR] ${err.stack || err.message}`;
  consoleLogs.push(entry);
  exceptions.push(entry);
});

console.log(`[driver] Navigating to initial URL: ${initialUrl}`);
try {
  await page.goto(initialUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });
} catch (err) {
  console.error(`[driver] Initial navigation warning: ${err.message}`);
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://unix');
  let body = '';
  req.on('data', (chunk) => { body += chunk; });
  req.on('end', async () => {
    let payload = {};
    if (body) {
      try { payload = JSON.parse(body); } catch (_) { payload = { raw: body }; }
    }

    try {
      switch (url.pathname) {
        case '/url': {
          res.writeHead(200, { 'Content-Type': 'text/plain' });
          res.end(page.url());
          break;
        }

        case '/goto': {
          const target = payload.url || initialUrl;
          await page.goto(target, { waitUntil: 'domcontentloaded', timeout: 30000 });
          res.writeHead(200, { 'Content-Type': 'text/plain' });
          res.end(page.url());
          break;
        }

        case '/texts': {
          const texts = await page.evaluate(() => {
            const results = [];
            const isVisible = (el) => {
              if (!el) return false;
              const style = window.getComputedStyle(el);
              if (style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') return false;
              const rect = el.getBoundingClientRect();
              return rect.width > 0 && rect.height > 0;
            };

            const walker = document.createTreeWalker(
              document.body,
              NodeFilter.SHOW_TEXT,
              {
                acceptNode: (node) => {
                  if (!node.textContent || !node.textContent.trim()) return NodeFilter.FILTER_REJECT;
                  const parent = node.parentElement;
                  if (!parent || parent.tagName === 'SCRIPT' || parent.tagName === 'STYLE') return NodeFilter.FILTER_REJECT;
                  if (!isVisible(parent)) return NodeFilter.FILTER_REJECT;
                  return NodeFilter.FILTER_ACCEPT;
                }
              }
            );

            let node;
            const seen = new Set();
            while ((node = walker.nextNode())) {
              const text = node.textContent.trim().replace(/\s+/g, ' ');
              const parent = node.parentElement;
              const rect = parent.getBoundingClientRect();
              const key = `${Math.round(rect.left)},${Math.round(rect.top)}:${text}`;
              if (!seen.has(key)) {
                seen.add(key);
                results.push(`[${Math.round(rect.left)}, ${Math.round(rect.top)}] ${text}`);
              }
            }
            return results;
          });

          res.writeHead(200, { 'Content-Type': 'text/plain' });
          res.end(texts.join('\n'));
          break;
        }

        case '/icons': {
          const icons = await page.evaluate(() => {
            const results = [];
            const elements = document.querySelectorAll('svg, [data-qa*="icon"], [aria-label], [title], .icon, [class*="hero-"]');
            elements.forEach((el) => {
              const rect = el.getBoundingClientRect();
              if (rect.width <= 0 || rect.height <= 0) return;
              const style = window.getComputedStyle(el);
              if (style.display === 'none' || style.visibility === 'hidden') return;

              let desc = el.getAttribute('data-qa') ||
                         el.getAttribute('aria-label') ||
                         el.getAttribute('title') ||
                         el.className ||
                         el.tagName.toLowerCase();
              if (typeof desc === 'object') desc = el.tagName.toLowerCase();
              results.push(`[${Math.round(rect.left)}, ${Math.round(rect.top)}] ${String(desc).trim()}`);
            });
            return results;
          });

          res.writeHead(200, { 'Content-Type': 'text/plain' });
          res.end(icons.join('\n'));
          break;
        }

        case '/tap': {
          const target = payload.target || '';
          const isLike = payload.like === true;

          const clicked = await page.evaluate(({ target, isLike }) => {
            const isVisible = (el) => {
              if (!el) return false;
              const style = window.getComputedStyle(el);
              if (style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') return false;
              const rect = el.getBoundingClientRect();
              return rect.width > 0 && rect.height > 0;
            };

            const candidates = Array.from(document.querySelectorAll('button, a, input[type="button"], input[type="submit"], [role="button"], span, div, h1, h2, h3, h4, label, [data-qa]'));
            for (const el of candidates) {
              if (!isVisible(el)) continue;
              const text = el.innerText || el.textContent || '';
              const matches = isLike
                ? text.toLowerCase().includes(target.toLowerCase())
                : text.trim() === target.trim();

              if (matches) {
                el.scrollIntoView({ block: 'center', inline: 'center' });
                el.click();
                return true;
              }
            }
            return false;
          }, { target, isLike });

          if (clicked) {
            res.writeHead(200, { 'Content-Type': 'text/plain' });
            res.end('OK');
          } else {
            res.writeHead(404, { 'Content-Type': 'text/plain' });
            res.end('NOT FOUND');
          }
          break;
        }

        case '/tapicon': {
          const code = payload.code || '';
          const clicked = await page.evaluate((code) => {
            const isVisible = (el) => {
              if (!el) return false;
              const style = window.getComputedStyle(el);
              if (style.display === 'none' || style.visibility === 'hidden') return false;
              const rect = el.getBoundingClientRect();
              return rect.width > 0 && rect.height > 0;
            };

            const candidates = Array.from(document.querySelectorAll('button, a, svg, [data-qa], [aria-label], [title], .icon'));
            for (const el of candidates) {
              if (!isVisible(el)) continue;
              const qa = el.getAttribute('data-qa') || '';
              const label = el.getAttribute('aria-label') || '';
              const title = el.getAttribute('title') || '';
              const text = el.innerText || el.textContent || '';

              if (qa.includes(code) || label.includes(code) || title.includes(code) || text.includes(code)) {
                el.scrollIntoView({ block: 'center', inline: 'center' });
                el.click();
                return true;
              }
            }
            return false;
          }, code);

          if (clicked) {
            res.writeHead(200, { 'Content-Type': 'text/plain' });
            res.end('OK');
          } else {
            res.writeHead(404, { 'Content-Type': 'text/plain' });
            res.end('NOT FOUND');
          }
          break;
        }

        case '/theme': {
          const themeInfo = await page.evaluate(() => {
            const body = document.body;
            const html = document.documentElement;
            const cs = window.getComputedStyle(body);
            const bg = cs.backgroundColor || window.getComputedStyle(html).backgroundColor || 'rgb(255, 255, 255)';
            const match = bg.match(/rgba?\((\d+),\s*(\d+),\s*(\d+)/);
            let brightness = 'light';
            if (match) {
              const r = Number(match[1]);
              const g = Number(match[2]);
              const b = Number(match[3]);
              const lum = 0.299 * r + 0.587 * g + 0.114 * b;
              brightness = lum < 128 ? 'dark' : 'light';
            } else if (html.classList.contains('dark')) {
              brightness = 'dark';
            }
            return `${brightness} (${bg})`;
          });

          res.writeHead(200, { 'Content-Type': 'text/plain' });
          res.end(themeInfo);
          break;
        }

        case '/eval': {
          const code = payload.code || '';
          let result;
          try {
            result = await page.evaluate(code);
            if (typeof result !== 'string') {
              result = JSON.stringify(result, null, 2);
            }
          } catch (evalErr) {
            result = `ERROR: ${evalErr.message}`;
          }
          res.writeHead(200, { 'Content-Type': 'text/plain' });
          res.end(String(result));
          break;
        }

        case '/shot': {
          const outPath = payload.path;
          if (!outPath) {
            res.writeHead(400, { 'Content-Type': 'text/plain' });
            res.end('Missing path');
            return;
          }
          fs.mkdirSync(path.dirname(outPath), { recursive: true });
          await page.screenshot({ path: outPath, fullPage: false });
          res.writeHead(200, { 'Content-Type': 'text/plain' });
          res.end(outPath);
          break;
        }

        case '/reload': {
          await page.reload({ waitUntil: 'domcontentloaded' });
          res.writeHead(200, { 'Content-Type': 'text/plain' });
          res.end('OK');
          break;
        }

        case '/console': {
          const count = payload.count || 40;
          const slice = consoleLogs.slice(-count);
          res.writeHead(200, { 'Content-Type': 'text/plain' });
          res.end(slice.join('\n'));
          break;
        }

        case '/exceptions': {
          res.writeHead(200, { 'Content-Type': 'text/plain' });
          if (exceptions.length === 0) {
            res.end('(none)\n--- 0 exceptions');
          } else {
            res.end(exceptions.join('\n') + `\n--- ${exceptions.length} exceptions`);
          }
          break;
        }

        case '/stop': {
          res.writeHead(200, { 'Content-Type': 'text/plain' });
          res.end('STOPPING');
          setTimeout(async () => {
            try { await browser.close(); } catch (_) {}
            try { fs.unlinkSync(socketPath); } catch (_) {}
            process.exit(0);
          }, 100);
          break;
        }

        default:
          res.writeHead(404, { 'Content-Type': 'text/plain' });
          res.end('Unknown endpoint');
      }
    } catch (handlerErr) {
      console.error('[driver] Handler error:', handlerErr);
      res.writeHead(500, { 'Content-Type': 'text/plain' });
      res.end(`ERROR: ${handlerErr.message}`);
    }
  });
});

server.listen(socketPath, () => {
  console.log(`[driver] Ready and listening on ${socketPath}`);
});

process.on('SIGTERM', async () => {
  try { await browser.close(); } catch (_) {}
  try { fs.unlinkSync(socketPath); } catch (_) {}
  process.exit(0);
});

process.on('SIGINT', async () => {
  try { await browser.close(); } catch (_) {}
  try { fs.unlinkSync(socketPath); } catch (_) {}
  process.exit(0);
});
