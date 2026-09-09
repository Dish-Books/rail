import { readFileSync } from 'node:fs'

const { openSession } = await import(process.env.DEMO_DRIVER)

const demo = await openSession({
  frameDir: process.env.DEMO_FRAME_DIR,
  port: Number(process.env.DEMO_PORT),
  debugPort: Number(process.env.DEMO_DEBUG_PORT)
})

// Authenticate and configure environment before recording
await demo.login(process.env.DEMO_LOGIN_URL)
await demo.goto('/select-organization/org_01kt20xzedtqf5z2v0fd23mqj1', 3000)

const attachmentId = readFileSync('/tmp/demo_attachment_id.txt', 'utf8').trim()
await demo.goto(`/accounting/expenses/bills/import/${attachmentId}`, 4000)

// Set up window dialog handling so confirm() automatically accepts
await demo.evaluate(`window.confirm = () => true;`)
demo.on('Page.javascriptDialogOpening', async () => {
  try {
    await demo.send('Page.handleJavaScriptDialog', { accept: true })
  } catch {}
})

demo.startCapture()

// Step 1: AP CSV import wizard & Column Mapping
await demo.step('AP CSV Import: column and reference mapping persist and resume across sessions', 3000)
await demo.expect("!!document.getElementById('column-mapping')", 'column mapping step visible')
await demo.expect("document.querySelector('#column-mapping-next[disabled]') !== null", 'next disabled before full mapping')

await demo.step('Category column was not auto-matched. Map it to GL Account to proceed.', 2600)
await demo.evaluate(`(() => {
  const sel = document.querySelector('select[name="gl_account"]');
  sel.value = "6";
  sel.dispatchEvent(new Event('input', { bubbles: true }));
  sel.dispatchEvent(new Event('change', { bubbles: true }));
})()`)
await demo.wait(1200)

await demo.expect("document.querySelector('#column-mapping-next:not([disabled])') !== null", 'next button enabled')
await demo.step('All required columns mapped. Advancing to reference mapping.', 2200)
await demo.click("document.getElementById('column-mapping-next')")
await demo.wait(2000)

// Step 2: Reference Mapping
await demo.expect("!!document.getElementById('reference-mapping')", 'reference mapping step visible')
await demo.expect("document.querySelector('#reference-mapping-next[disabled]') !== null", 'reference next disabled initially')
await demo.step("Step 2: Reference Mapping. 'Hudson Greens' is an unrecognized vendor.", 2800)

await demo.step("Click 'Create vendor' to immediately create and map Hudson Greens.", 2200)
await demo.expect("!!document.getElementById('create-vendor-0')", 'create vendor button exists')
await demo.click("document.getElementById('create-vendor-0')")
await demo.wait(2000)

await demo.expect("document.querySelector('#reference-mapping-next:not([disabled])') !== null", 'reference next enabled')
await demo.step('Vendor created and mapped. Now reload the page to verify persistence.', 2800)

// Step 3: Persistence across reload
await demo.evaluate('window.location.reload()')
await demo.wait(3500)
await demo.evaluate(`window.confirm = () => true;`)

await demo.expect("!!document.getElementById('reference-mapping')", 'resumed on reference mapping step')
await demo.expect("document.querySelector('#reference-mapping-next:not([disabled])') !== null", 'mapping progress intact after reload')
await demo.step('Page reloaded: mapping progress and created vendor reference persisted intact.', 3000)

await demo.step('Proceeding to document preview.', 2000)
await demo.click("document.getElementById('reference-mapping-next')")
await demo.wait(2500)

// Step 4: Preview
await demo.expect("!!document.getElementById('import-preview')", 'preview step visible')
await demo.expect("!!document.getElementById('document-INV-9001')", 'INV-9001 rendered in preview')
await demo.expect("!!document.getElementById('document-INV-9002')", 'INV-9002 rendered in preview')
await demo.step('Both bills successfully previewed with resolved references.', 2600)

// Step 5: Viewing the run in Settings -> Documents -> Imports tab
await demo.step('Import runs are tracked under Settings > Documents > Imports tab.', 2800)
await demo.goto('/settings/documents?tab=imports', 3500)
await demo.expect("!!document.getElementById('imports-list')", 'imports list visible')
await demo.expect("document.getElementById('imports-list').textContent.includes('ap_bills_import.csv')", 'import row visible in list')
await demo.expect("document.getElementById('imports-list').textContent.includes('In progress')", 'status is in progress')

await demo.step("Clicking the import from the Imports tab resumes the in-progress run.", 2600)
await demo.click("[...document.querySelectorAll('#imports-list a')].find(a => a.textContent.includes('ap_bills_import.csv'))")
await demo.wait(3500)
await demo.evaluate(`window.confirm = () => true;`)

// Step 6: Explicit discard resetting the import
await demo.expect("!!document.getElementById('import-preview')", 'resumed back on preview step')
await demo.step("Resumed on preview. Click 'Discard import' to reset and start over.", 2800)
await demo.expect("!!document.getElementById('discard-import')", 'discard import button visible')
await demo.click("document.getElementById('discard-import')")
await demo.wait(2500)

await demo.expect("!!document.getElementById('column-mapping')", 'wizard reset back to column mapping step')
await demo.refute("!!document.getElementById('document-INV-9001')", 'preview documents cleared')
await demo.step('Import explicitly discarded: run reset to Step 1 with a clean slate.', 3200)

console.log(`FRAMES ${await demo.finish()}`)
