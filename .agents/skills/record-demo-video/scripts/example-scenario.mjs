// Worked example: the DIS-903 closing date flow. Copy this into the scratchpad and rewrite the steps
// for the feature being demonstrated.
//
// Run through record.sh, which supplies the env vars and encodes the result. The driver is imported by
// the path record.sh injects, so a scenario works from wherever it is saved.
const { openSession } = await import(process.env.DEMO_DRIVER)

const demo = await openSession({
  frameDir: process.env.DEMO_FRAME_DIR,
  port: Number(process.env.DEMO_PORT),
  debugPort: Number(process.env.DEMO_DEBUG_PORT)
})

// Authenticate and get to the starting screen before recording, so the video opens on the feature.
await demo.login(process.env.DEMO_LOGIN_URL)
await demo.goto('/settings/accounting', 4000)
await demo.evaluate(`document.getElementById('closing-dates')?.scrollIntoView({block: 'center'})`)
await demo.wait(800)

demo.startCapture()

const dateInput = `document.querySelector('#closing-date-form input[type=date]')`
const reasonBox = `document.querySelector('#closing-date-form textarea')`

await demo.step('Closing Dates, one row per Entity, with the books-closed-through indicator', 2600)
await demo.step('Casa Verde LLC is closed through Jun 30, 2026. Open it.', 1800)
await demo.click(`[...document.querySelectorAll('[id^="edit-closing-date-"]')][1]`)
await demo.wait(1200)

await demo.step('Advance it forward to Jul 31: routine month end, no reason asked', 1500)
await demo.typeDate(dateInput, '07312026', '2026-07-31')
await demo.wait(1400)
await demo.refute(`!!${reasonBox}`, 'reason field on a forward move')

await demo.step('Now move it backward to May 31. That reopens a closed period.', 1800)
await demo.typeDate(dateInput, '05312026', '2026-05-31')
await demo.wait(1600)
await demo.expect(`!!${reasonBox}`, 'reason field on a backward move')

await demo.step('The reason field appeared on the date change alone, before any save', 2600)
await demo.step('Saving with it empty is refused', 1200)
await demo.click(`document.querySelector('#closing-date-form button[type=submit]')`)
await demo.wait(2400)

await demo.step('Give a reason and the reopen goes through', 1200)
await demo.click(reasonBox)
await demo.type('correcting misposted Sysco invoice per owner request')
await demo.wait(1200)
await demo.click(`document.querySelector('#closing-date-form button[type=submit]')`)
await demo.wait(2600)

await demo.step('Saved. The indicator now reads May 31, 2026.', 2800)
await demo.step('Every change is audited; the reason lands on the audit entry, not on the Entity.', 3000)

console.log(`FRAMES ${await demo.finish()}`)
