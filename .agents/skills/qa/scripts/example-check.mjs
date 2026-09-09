// Worked example of one checklist item. Copy into the scratchpad, rewrite, run with
// `qa.sh run <file>`. Keep each file to one or two checklist rows so a failure names itself.
//
// Everything printed here ends up in the QA report, so print evidence (values, paths, problems),
// not narration.
const { openQaSession } = await import(process.env.QA_DRIVER)

const qa = await openQaSession({
  port: Number(process.env.QA_PORT),
  debugPort: Number(process.env.QA_DEBUG_PORT),
  scratchDir: process.env.QA_SCRATCH
})

const fail = (message) => {
  console.log(`FAIL ${message}`)
  process.exitCode = 1
}

// --- check: the GL accounts page lists accounts and the CSV import entry point is reachable ---
await qa.goto('/settings/gl-accounts')

const heading = await qa.evaluate(`document.querySelector('h1')?.textContent?.trim()`)
if (heading !== 'GL Accounts') fail(`heading reads ${JSON.stringify(heading)}`)

const rows = await qa.evaluate(`document.querySelectorAll('tbody tr').length`)
console.log(`rows: ${rows}`)
if (rows === 0) fail('no rows: is this an empty state or a broken query?')

// Read the returned path with the Read tool. A screenshot catches what an assertion cannot:
// misalignment, a number formatted as 1234.5 instead of $1,234.50, text clipped out of its column.
console.log(`shot: ${await qa.shot('gl-accounts')}`)

// --- check: it survives a narrow viewport ---
await qa.resize(375, 812)
console.log(`shot: ${await qa.shot('gl-accounts-mobile')}`)
const overflows = await qa.evaluate(`document.documentElement.scrollWidth > window.innerWidth + 2`)
if (overflows) fail('page scrolls horizontally at 375px')
await qa.resize(1280, 860)

// Always drain. A check that looks right and logs a 500 or a LiveView crash has still failed.
for (const problem of qa.drainProblems()) console.log(`PROBLEM ${problem.kind}: ${problem.detail}`)

await qa.finish()
