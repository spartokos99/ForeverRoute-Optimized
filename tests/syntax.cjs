// Usage: NODE_PATH must contain luaparse when it is installed outside this repository.
const fs = require("node:fs");
const path = require("node:path");
const lua = require("luaparse");
const root = path.resolve(__dirname, "..");
let count = 0;

function check(directory) {
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const file = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      check(file);
    } else if (file.endsWith(".lua")) {
      try {
        lua.parse(fs.readFileSync(file, "utf8"), { luaVersion: "5.1" });
        count++;
      } catch (error) {
        console.error(`${path.relative(root, file)}: ${error.message}`);
        process.exitCode = 1;
      }
    }
  }
}

check(path.join(root, "addon"));
check(path.join(root, "tests"));
console.log(`Lua 5.1 syntax checked: ${count} files`);
