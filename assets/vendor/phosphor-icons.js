const plugin = require("tailwindcss/plugin")
const fs = require("fs")
const path = require("path")

// Generates a `pi-<icon>` component class for every Phosphor icon, drawn as a CSS
// mask so the icon takes its color from `currentColor` and its size from the
// element's own width/height classes. Regular weight is the bare name
// (`pi-gear`); other weights carry the suffix Phosphor ships (`pi-gear-fill`).
module.exports = plugin(function ({ matchComponents }) {
  let baseDir = path.join(__dirname, "../node_modules/@phosphor-icons/core/assets")
  let values = {}
  let weights = fs
    .readdirSync(baseDir, { withFileTypes: true })
    .filter((dirent) => dirent.isDirectory())
    .map((dirent) => dirent.name)

  weights.forEach((dir) => {
    fs.readdirSync(path.join(baseDir, dir)).map((file) => {
      let name = path.basename(file, ".svg")

      values[name] = { name, fullPath: path.join(baseDir, dir, file) }
    })
  })

  matchComponents(
    {
      pi: ({ name, fullPath }) => {
        let content = fs.readFileSync(fullPath).toString().replace(/\r?\n|\r/g, "")

        return {
          [`--pi-${name}`]: `url('data:image/svg+xml;utf8,${content}')`,
          "-webkit-mask": `var(--pi-${name})`,
          mask: `var(--pi-${name})`,
          "background-color": "currentColor",
          "vertical-align": "middle",
          display: "inline-block",
          "mask-repeat": "no-repeat",
          "mask-position": "center",
          "-webkit-mask-repeat": "no-repeat",
        }
      },
    },
    { values }
  )
})
