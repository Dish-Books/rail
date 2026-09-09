// Drives a headless Chrome over the DevTools Protocol and writes one PNG per frame, so the resulting
// video is a recording of the running app rather than a reenactment.
//
// Why CDP instead of the in-app Browser pane: `Input.dispatchMouseEvent` and `Input.dispatchKeyEvent`
// produce trusted events, so `phx-click` / `phx-change` fire exactly as they do for a real user. A
// synthetic `element.click()` or `new Event('input')` races LiveView's re-render and silently no-ops.
//
// Zero dependencies: Node has a global WebSocket, so nothing needs installing.
import { mkdirSync, writeFileSync, readFileSync, rmSync } from 'node:fs'
import { basename, join } from 'node:path'

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

// LiveView validates an entry against the `accept` list using the browser-reported type, so an
// upload driven from here has to carry the same type a real pick would. Pass `contentType` to send
// something else deliberately - a .png the browser calls image/gif is a real case worth testing.
const mimeTypes = {
  csv: 'text/csv',
  jpeg: 'image/jpeg',
  jpg: 'image/jpeg',
  pdf: 'application/pdf',
  png: 'image/png',
  qbo: 'application/vnd.intu.qbo',
  webp: 'image/webp'
}

const mimeOf = (path) => mimeTypes[path.split('.').pop().toLowerCase()] ?? 'application/octet-stream'

export async function openSession({
  frameDir,
  port = 4000,
  debugPort = 9222,
  width = 1280,
  height = 860,
  frameIntervalMs = 120
}) {
  rmSync(frameDir, { recursive: true, force: true })
  mkdirSync(frameDir, { recursive: true })

  const targets = await (await fetch(`http://127.0.0.1:${debugPort}/json/list`)).json()
  const target = targets.find((t) => t.type === 'page')
  if (!target) throw new Error(`no page target on port ${debugPort}; is Chrome running?`)

  const ws = new WebSocket(target.webSocketDebuggerUrl)
  await new Promise((resolve, reject) => {
    ws.addEventListener('open', resolve)
    ws.addEventListener('error', () => reject(new Error('could not attach to Chrome')))
  })

  let nextId = 1
  const pending = new Map()
  const listeners = new Map()
  ws.addEventListener('message', (event) => {
    const message = JSON.parse(event.data)
    // CDP events carry a method and no id; the qa skill subscribes to them for console errors and
    // failed responses.
    if (!message.id) {
      for (const handler of listeners.get(message.method) ?? []) handler(message.params)
      return
    }
    if (!pending.has(message.id)) return
    const { resolve, reject } = pending.get(message.id)
    pending.delete(message.id)
    message.error ? reject(new Error(JSON.stringify(message.error))) : resolve(message.result)
  })

  const send = (method, params = {}) =>
    new Promise((resolve, reject) => {
      const id = nextId++
      pending.set(id, { resolve, reject })
      ws.send(JSON.stringify({ id, method, params }))
    })

  const evaluate = async (expression) => {
    const { result } = await send('Runtime.evaluate', {
      expression,
      returnByValue: true,
      awaitPromise: true
    })
    return result.value
  }

  let frames = 0
  let inFlight = false
  let ticker = null

  // Frames come off a timer for the whole run rather than one per action, so the video carries the
  // app's real response times instead of a slideshow of end states.
  // The race is not optional: Chrome silently drops a screenshot command the page navigated out
  // from under, so an un-timed `await` never settles, `inFlight` never clears, and capture stops
  // for the rest of the run without erroring.
  const timeout = (ms) =>
    new Promise((_resolve, reject) => setTimeout(() => reject(new Error('screenshot timed out')), ms))

  const captureFrame = async () => {
    if (inFlight) return
    inFlight = true
    try {
      const { data } = await Promise.race([send('Page.captureScreenshot', { format: 'png' }), timeout(2500)])
      const name = `frame-${String(++frames).padStart(5, '0')}.png`
      writeFileSync(join(frameDir, name), Buffer.from(data, 'base64'))
    } catch {
      // a screenshot that lands mid-navigation is not worth failing the run over
    } finally {
      inFlight = false
    }
  }

  const boxOf = (selectorExpression, at) =>
    evaluate(`
      (() => {
        const el = ${selectorExpression}
        if (!el) return null
        const r = el.getBoundingClientRect()
        return { x: ${at === 'left' ? 'r.left + 22' : 'r.left + r.width / 2'}, y: r.top + r.height / 2 }
      })()
    `)

  const pressKey = async (key, keyCode) => {
    for (const type of ['rawKeyDown', 'keyUp']) {
      await send('Input.dispatchKeyEvent', { type, key, code: key, windowsVirtualKeyCode: keyCode })
    }
    await sleep(60)
  }

  const session = {
    frameDir,
    get frames() {
      return frames
    },

    evaluate,
    wait: sleep,

    // Raw CDP access, for callers that need a domain this driver does not wrap (Network, Log).
    send,
    on: (method, handler) => listeners.set(method, [...(listeners.get(method) ?? []), handler]),

    // `selectorExpression` is JS evaluated in the page, so it can be a querySelector or a find over
    // textContent when nothing stable identifies the element.
    async click(selectorExpression, { at = 'center' } = {}) {
      const box = await boxOf(selectorExpression, at)
      if (!box) throw new Error(`nothing to click for ${selectorExpression}`)
      for (const type of ['mousePressed', 'mouseReleased']) {
        await send('Input.dispatchMouseEvent', { type, ...box, button: 'left', clickCount: 1 })
      }
      await sleep(200)
    },

    // Enter/Tab/Escape as trusted key events, for a combobox that commits on Enter rather than on a
    // click, and for closing a modal.
    press: pressKey,

    // A CSS-only tooltip (`group-hover:block`) needs a real pointer over the element: a dispatched
    // `mouseover` never sets `:hover`, so the tooltip would stay hidden in every frame.
    async hover(selectorExpression) {
      const box = await boxOf(selectorExpression, 'center')
      if (!box) throw new Error(`nothing to hover for ${selectorExpression}`)
      await send('Input.dispatchMouseEvent', { type: 'mouseMoved', ...box })
      await sleep(300)
    },

    async type(text) {
      for (const char of text) {
        for (const type of ['keyDown', 'keyUp']) {
          await send('Input.dispatchKeyEvent', { type, text: char })
        }
        await sleep(45)
      }
    },

    // `DOM.setFileInputFiles` is not enough for a LiveView upload: it puts the files on the input,
    // but LiveView only learns about files through its own `track-uploads` window event (or a real
    // drop), so no entry ref is ever allocated and the upload silently does not exist - which reads
    // exactly like a broken feature. So this hands LiveView real `File` objects the way its own JS
    // interop does. Works on a `class="hidden"` input, which is how the app styles them.
    async upload(selectorExpression, paths, { contentType = null } = {}) {
      const files = paths.map((path) => {
        const bytes = readFileSync(path)
        // The bytes ride to the page inside the evaluated expression, so keep this to fixtures.
        if (bytes.length > 8_000_000) throw new Error(`${path} is too large to upload this way`)
        return { name: basename(path), type: contentType ?? mimeOf(path), data: bytes.toString('base64') }
      })

      const registered = await evaluate(`
        (() => {
          const el = ${selectorExpression}
          if (!el) return 'no element'
          const files = ${JSON.stringify(files)}.map(({ name, type, data }) => {
            const bytes = Uint8Array.from(atob(data), (char) => char.charCodeAt(0))
            return new File([bytes], name, { type })
          })
          // LiveView binds this on window and dispatches the input event itself, so it must bubble.
          el.dispatchEvent(new CustomEvent('track-uploads', { detail: { files }, bubbles: true }))
          return 'dispatched'
        })()
      `)
      if (registered !== 'dispatched') throw new Error(`nothing to upload to for ${selectorExpression}`)

      // The refs are allocated when the server answers the preflight, and an `auto_upload` entry is
      // cleared again once consumed - so poll for them appearing rather than reading once.
      for (let attempt = 0; attempt < 40; attempt++) {
        const refs = await evaluate(`
          ['active', 'preflighted', 'done']
            .map((kind) => ${selectorExpression}.getAttribute('data-phx-' + kind + '-refs') || '')
            .filter((refs) => refs !== '')
            .join(' ')
        `)
        if (refs !== '') return refs
        await sleep(150)
      }

      throw new Error(`LiveView never registered an upload entry for ${selectorExpression}`)
    },

    // Date inputs keep focus on whichever segment was last edited, so a second date typed into the
    // same field lands in the year and silently overflows it (07/31/275760). Walk back to the month
    // segment first, then assert the value so a bad take fails loudly instead of being recorded.
    async typeDate(selectorExpression, digits, expected) {
      await session.click(selectorExpression, { at: 'left' })
      for (let i = 0; i < 3; i++) await pressKey('ArrowLeft', 37)
      await session.type(digits)
      await sleep(900)
      const value = await evaluate(`${selectorExpression}.value`)
      if (value !== expected) throw new Error(`date input reads ${value}, expected ${expected}`)
    },

    // Assert the UI state the narration claims, so a wrong take fails instead of shipping a
    // misleading video.
    async expect(jsExpression, description) {
      if (!(await evaluate(jsExpression))) throw new Error(`expected ${description}`)
    },

    async refute(jsExpression, description) {
      if (await evaluate(jsExpression)) throw new Error(`expected no ${description}`)
    },

    // Deliberately styled as an obvious overlay: narration must never be mistakable for app UI.
    caption: (text) =>
      evaluate(`
        (() => {
          let bar = document.getElementById('demo-caption')
          if (!bar) {
            bar = document.createElement('div')
            bar.id = 'demo-caption'
            bar.style.cssText = 'position:fixed;left:0;right:0;bottom:0;z-index:99999;' +
              'background:rgba(10,10,12,.92);color:#e8e8ea;padding:14px 22px;letter-spacing:.2px;' +
              'font:500 20px ui-monospace,SFMono-Regular,Menlo,monospace;border-top:2px solid #6c7cf5'
            document.body.appendChild(bar)
          }
          bar.textContent = ${JSON.stringify(text)}
        })()
      `),

    // Narrate and hold, so there is time to read the caption before the next action.
    async step(text, ms = 2400) {
      if (text !== null) await session.caption(text)
      await sleep(ms)
    },

    goto: async (path, settleMs = 3500) => {
      await send('Page.navigate', { url: `http://localhost:${port}${path}` })
      await sleep(settleMs)
    },

    // Magic link only: never type a password. The page renders `#confirmation_form` for a user who
    // has never confirmed and `#login_form` for one who has, with four different button labels
    // between them — so matching on copy worked exactly once per user and then broke forever. Target
    // whichever form is there and take its remember-me button, falling back to its first submit.
    async login(magicUrl) {
      const confirm = `(() => {
        const form = document.querySelector('#confirmation_form, #login_form')
        if (!form) return null
        const buttons = [...form.querySelectorAll('button:not([type=button])')]
        return buttons.find((b) => b.name.includes('remember_me')) ?? buttons[0] ?? null
      })()`
      await send('Page.navigate', { url: magicUrl })
      await sleep(3500)
      if (await evaluate(`!!(${confirm})`)) {
        await session.click(confirm)
        await sleep(3000)
      }
    },

    startCapture() {
      ticker = setInterval(captureFrame, frameIntervalMs)
    },

    async finish() {
      if (ticker) clearInterval(ticker)
      await sleep(400)
      ws.close()
      return frames
    }
  }

  await send('Page.enable')
  await send('Runtime.enable')
  await send('Emulation.setDeviceMetricsOverride', {
    width,
    height,
    deviceScaleFactor: 1,
    mobile: false
  })

  return session
}
