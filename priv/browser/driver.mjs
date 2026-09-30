// Drives one tab of Rail's shared headless Chrome over the DevTools protocol. `browser_connect` copies
// this file into the task's scratch directory and says which tab is yours.
//
//   import { openBrowser } from '<scratch>/browser/driver.mjs'
//   const b = await openBrowser('ws://127.0.0.1:PORT/devtools/page/TARGET')
//   await b.goto('http://localhost:4000/bills/new')
//   await b.click(`document.querySelector('#bill_vendor')`)
//   await b.type('Sysco')
//   await b.press('Enter')
//   console.log(await b.evaluate(`document.querySelector('#bill_amount').value`))
//   for (const p of b.drainProblems()) console.log(`PROBLEM ${p.kind}: ${p.detail}`)
//   await b.close()
//
// Why CDP input rather than `element.click()`: `Input.dispatchMouseEvent` and `Input.dispatchKeyEvent`
// produce trusted events, so `phx-click` / `phx-change` fire exactly as they do for a real user. A
// synthetic `element.click()` or `new Event('input')` races LiveView's re-render and silently no-ops -
// which looks exactly like a feature that silently no-ops, so a check built on it proves nothing.
//
// Rail watches the same tab (the panel, the demo recording), so what you do here is what they see.
// The viewport starts at 1920x1080; put it back if you resize.
//
// Zero dependencies: Node 22 has a global WebSocket.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { basename, dirname } from 'node:path'

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

// LiveView validates an entry against the `accept` list using the browser-reported type, so an
// upload driven from here has to carry the same type a real pick would.
const mimeTypes = {
  csv: 'text/csv',
  jpeg: 'image/jpeg',
  jpg: 'image/jpeg',
  pdf: 'application/pdf',
  png: 'image/png',
  qbo: 'application/vnd.intu.qbo',
  txt: 'text/plain',
  webp: 'image/webp',
  xlsx: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
}

const mimeOf = (path) => mimeTypes[path.split('.').pop().toLowerCase()] ?? 'application/octet-stream'

// Chrome names a key from its code and the text it carries. No native key code: that is the
// platform's own numbering, and a Windows code sent as a Mac one names some other key.
const keys = {
  Enter: { code: 'Enter', keyCode: 13, text: '\r' },
  Tab: { code: 'Tab', keyCode: 9, text: '\t' },
  Escape: { code: 'Escape', keyCode: 27 },
  Backspace: { code: 'Backspace', keyCode: 8 },
  Delete: { code: 'Delete', keyCode: 46 },
  Space: { code: 'Space', keyCode: 32, text: ' ' },
  ArrowLeft: { code: 'ArrowLeft', keyCode: 37 },
  ArrowUp: { code: 'ArrowUp', keyCode: 38 },
  ArrowRight: { code: 'ArrowRight', keyCode: 39 },
  ArrowDown: { code: 'ArrowDown', keyCode: 40 },
  Home: { code: 'Home', keyCode: 36 },
  End: { code: 'End', keyCode: 35 },
  PageUp: { code: 'PageUp', keyCode: 33 },
  PageDown: { code: 'PageDown', keyCode: 34 }
}

export async function openBrowser(pageUrl) {
  const ws = new WebSocket(pageUrl)
  await new Promise((resolve, reject) => {
    ws.addEventListener('open', resolve)
    ws.addEventListener('error', () =>
      reject(new Error(`could not attach to ${pageUrl}; call browser_connect again for your tab's address`))
    )
  })

  let nextId = 1
  const pending = new Map()
  const listeners = new Map()
  ws.addEventListener('message', (event) => {
    const message = JSON.parse(event.data)
    if (!message.id) {
      for (const handler of listeners.get(message.method) ?? []) handler(message.params)
      return
    }
    if (!pending.has(message.id)) return
    const { resolve, reject } = pending.get(message.id)
    pending.delete(message.id)
    message.error ? reject(new Error(`${JSON.stringify(message.error)}`)) : resolve(message.result)
  })

  const send = (method, params = {}) =>
    new Promise((resolve, reject) => {
      const id = nextId++
      pending.set(id, { resolve, reject })
      ws.send(JSON.stringify({ id, method, params }))
    })

  const on = (method, handler) => listeners.set(method, [...(listeners.get(method) ?? []), handler])

  // Throws what the page threw, so a wrong selector fails the script where it was written.
  const evaluate = async (expression) => {
    const { result, exceptionDetails } = await send('Runtime.evaluate', {
      expression,
      returnByValue: true,
      awaitPromise: true
    })
    if (exceptionDetails) {
      throw new Error(`${expression} threw: ${exceptionDetails.exception?.description ?? exceptionDetails.text}`)
    }
    return result.value
  }

  // Scrolled into view first: below the fold is somewhere the page would show anybody who asked.
  // `covered` names whatever is drawn over the point, because a trusted click lands on it instead.
  const locate = (selectorExpression, at) =>
    evaluate(`
      (() => {
        const el = ${selectorExpression}
        if (!(el instanceof Element)) return null
        let r = el.getBoundingClientRect()
        if (r.top < 0 || r.bottom > innerHeight || r.left < 0 || r.right > innerWidth) {
          el.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'instant' })
          r = el.getBoundingClientRect()
        }
        const x = ${at === 'left' ? 'r.left + Math.min(22, r.width / 2)' : 'r.left + r.width / 2'}
        const y = r.top + r.height / 2
        const top = document.elementFromPoint(x, y)
        const covered = top && top !== el && !el.contains(top) ? top.outerHTML.slice(0, 120) : null
        return { x, y, width: r.width, height: r.height, covered }
      })()
    `)

  const point = async (selectorExpression, at, verb) => {
    const box = await locate(selectorExpression, at)
    if (!box) throw new Error(`nothing to ${verb} for ${selectorExpression}`)
    if (!box.width || !box.height) throw new Error(`${selectorExpression} has no size: hidden, or not rendered yet`)
    if (box.covered) console.warn(`${verb} ${selectorExpression}: covered by ${box.covered}, which takes the event`)
    return box
  }

  // Collected rather than thrown: a check wants the whole list at the end of a flow, not to abort on
  // the first warning. Drain per check so each is attributed to the step that caused it.
  const problems = []
  const note = (kind, detail) => problems.push({ kind, detail })
  on('Runtime.consoleAPICalled', ({ type, args }) => {
    if (type !== 'error' && type !== 'warning') return
    note(`console.${type}`, args.map((a) => a.value ?? a.description ?? a.type).join(' '))
  })
  on('Runtime.exceptionThrown', ({ exceptionDetails }) =>
    note('uncaught exception', exceptionDetails.exception?.description ?? exceptionDetails.text)
  )
  on('Log.entryAdded', ({ entry }) => {
    if (entry.level !== 'error' && entry.level !== 'warning') return
    if (/software WebGL|GPU stall|swiftshader|GroupMarkerNotSet/i.test(entry.text)) return
    note(`browser ${entry.level}`, `${entry.text} ${entry.url ?? ''}`.trim())
  })
  on('Network.responseReceived', ({ response }) => {
    if (response.status >= 400) note(`http ${response.status}`, response.url)
  })
  // A LiveView that crashes server-side drops the socket and reconnects, which is invisible in a
  // screenshot but is always a bug worth reporting.
  on('Network.webSocketClosed', ({ requestId }) => note('websocket closed', requestId))

  await send('Page.enable')
  await send('Runtime.enable')
  await send('Log.enable')
  await send('Network.enable')

  const press = async (key) => {
    const known = keys[key]
    if (!known) throw new Error(`press knows ${Object.keys(keys).join(', ')}; type anything else`)
    const params = { key, code: known.code, windowsVirtualKeyCode: known.keyCode }
    await send('Input.dispatchKeyEvent', known.text ? { ...params, type: 'keyDown', text: known.text } : { ...params, type: 'rawKeyDown' })
    await send('Input.dispatchKeyEvent', { ...params, type: 'keyUp' })
    await sleep(60)
  }

  const type = async (text) => {
    for (const char of text) {
      await send('Input.dispatchKeyEvent', { type: 'keyDown', text: char })
      await send('Input.dispatchKeyEvent', { type: 'keyUp', text: char })
      await sleep(45)
    }
  }

  const browser = {
    send,
    on,
    evaluate,
    wait: sleep,

    // `selectorExpression` is JS evaluated in the page returning the element: a querySelector, or a
    // find over textContent when nothing stable identifies it.
    async click(selectorExpression, { at = 'center' } = {}) {
      const { x, y } = await point(selectorExpression, at, 'click')
      await send('Input.dispatchMouseEvent', { type: 'mouseMoved', x, y })
      for (const type of ['mousePressed', 'mouseReleased']) {
        await send('Input.dispatchMouseEvent', { type, x, y, button: 'left', clickCount: 1 })
      }
      await sleep(200)
    },

    // A CSS-only tooltip (`group-hover:block`) needs a real pointer over the element: a dispatched
    // `mouseover` never sets `:hover`.
    async hover(selectorExpression) {
      const { x, y } = await point(selectorExpression, 'center', 'hover')
      await send('Input.dispatchMouseEvent', { type: 'mouseMoved', x, y })
      await sleep(300)
    },

    press,
    type,

    // Selects what the focused field holds, so the next `type` replaces it.
    async selectAll() {
      const modifiers = process.platform === 'darwin' ? 4 : 2
      await send('Input.dispatchKeyEvent', { type: 'keyDown', key: 'a', code: 'KeyA', modifiers, commands: ['selectAll'] })
      await send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'a', code: 'KeyA', modifiers })
    },

    // A native <select>'s list is drawn by the OS and no click reaches it, so it is set and told.
    async select(selectorExpression, value) {
      const chosen = await evaluate(`
        (() => {
          const el = ${selectorExpression}
          if (!(el instanceof HTMLSelectElement)) return 'not a select'
          el.value = ${JSON.stringify(value)}
          if (el.value !== ${JSON.stringify(value)}) return 'no such option'
          el.dispatchEvent(new Event('input', { bubbles: true }))
          el.dispatchEvent(new Event('change', { bubbles: true }))
          return 'ok'
        })()
      `)
      if (chosen !== 'ok') throw new Error(`select ${selectorExpression} ${JSON.stringify(value)}: ${chosen}`)
      await sleep(200)
    },

    // Date inputs keep focus on whichever segment was last edited, so a second date typed into the
    // same field lands in the year and silently overflows it. Walk back to the first segment, type the
    // digits in the order the field shows them, then assert the value so a bad run fails loudly.
    async typeDate(selectorExpression, digits, expected) {
      await browser.click(selectorExpression, { at: 'left' })
      for (let i = 0; i < 3; i++) await press('ArrowLeft')
      await type(digits)
      await sleep(900)
      const value = await evaluate(`${selectorExpression}.value`)
      if (value !== expected) throw new Error(`date input reads ${value}, expected ${expected}`)
    },

    // `DOM.setFileInputFiles` is not enough for a LiveView upload: LiveView only learns about files
    // through its own `track-uploads` event, so no entry is ever allocated and the upload silently
    // does not exist. This hands LiveView real `File` objects the way its own JS interop does. Pass
    // `contentType` to send a type the browser would not infer.
    async upload(selectorExpression, paths, { contentType = null } = {}) {
      const files = paths.map((path) => {
        const bytes = readFileSync(path)
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
          el.dispatchEvent(new CustomEvent('track-uploads', { detail: { files }, bubbles: true }))
          return 'dispatched'
        })()
      `)
      if (registered !== 'dispatched') throw new Error(`nothing to upload to for ${selectorExpression}`)

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

    // Assert the state a check or a caption claims, so a wrong run fails instead of passing.
    async expect(jsExpression, description) {
      if (!(await evaluate(jsExpression))) throw new Error(`expected ${description}`)
    },

    async refute(jsExpression, description) {
      if (await evaluate(jsExpression)) throw new Error(`expected no ${description}`)
    },

    // Waits for an expression to become truthy, for a LiveView patch or a navigation to land.
    async until(jsExpression, { timeoutMs = 10_000, description = jsExpression } = {}) {
      const deadline = Date.now() + timeoutMs
      while (Date.now() < deadline) {
        try {
          if (await evaluate(jsExpression)) return
        } catch {
          // a document mid-navigation has nothing to evaluate against yet
        }
        await sleep(100)
      }
      throw new Error(`timed out waiting for ${description}`)
    },

    // A path is resolved against the page the tab is on.
    async goto(url, settleMs = 1500) {
      const target = /^[a-z]+:/i.test(url) ? url : new URL(url, await evaluate('location.href')).href
      const { errorText } = await send('Page.navigate', { url: target })
      if (errorText) throw new Error(`could not open ${target}: ${errorText}`)
      await sleep(settleMs)
    },

    // The visible text of the page, for asserting copy and for spotting a raw error or a stray `nil`.
    text: () => evaluate('document.body.innerText'),

    // A PNG you read back with the Read tool, for your own eyes. Evidence for the human goes
    // through qa_shot, which files it against a check.
    async shot(path) {
      const { data } = await send('Page.captureScreenshot', { format: 'png' })
      mkdirSync(dirname(path), { recursive: true })
      writeFileSync(path, Buffer.from(data, 'base64'))
      return path
    },

    // Narrow viewport check without another tab. Put it back with resize(1920, 1080).
    async resize(width, height) {
      await send('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: 1, mobile: width < 768 })
      await sleep(400)
    },

    // Everything the tab complained about since the last drain.
    drainProblems: () => problems.splice(0, problems.length),

    // Leaves the tab where it is: the next script, and Rail, pick up from here.
    async close() {
      await sleep(100)
      ws.close()
    }
  }

  return browser
}
