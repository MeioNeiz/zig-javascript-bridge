// node test/run.mjs zjb.js test.wasm: runs test/main.zig through the generated bridge.
import { readFile } from "node:fs/promises";

const [jsPath, wasmPath] = process.argv.slice(2);
const source = await readFile(jsPath, "utf8");
const wasm = await readFile(wasmPath);
const response = () => new Response(wasm, { headers: { "content-type": "application/wasm" } });

// Evaluates the generated script as a page would, with `document` and `fetch` stubbed.
function evaluate(document, fetch) {
  return new Function("document", "fetch", `${source}\nreturn Zjb;`)(document, fetch);
}

let failed = 0;
function check(name, ok, detail = "") {
  console.log(`${ok ? "ok" : "FAIL"} ${name}${ok ? "" : ` ${detail}`}`);
  if (!ok) failed++;
}

{
  const fetched = [];
  const document = {
    currentScript: { src: "https://example.com/js/zjb.js", dataset: { wasm: "../app.wasm" } },
  };
  const Zjb = evaluate(document, (url) => {
    fetched.push(String(url));
    return Promise.resolve(response());
  });
  const bridge = await Zjb.ready;
  check("loader fetches data-wasm relative to the script", fetched[0] === "https://example.com/app.wasm", fetched[0]);
  check("loader calls main", bridge.exports.mainRan() === true);
}

{
  const document = { currentScript: { src: "https://example.com/zjb.js", dataset: {} } };
  const Zjb = evaluate(document, () => check("no fetch without data-wasm", false));
  check("no data-wasm, nothing loaded", Zjb.ready === undefined);
}

const Zjb = evaluate(undefined, undefined);
const bridge = await Zjb.load(response());
check("load does not call main", bridge.exports.mainRan() === false);

// "check" exports run after the promises the "test" exports started have settled.
for (const prefix of ["test", "check"]) {
  for (const name of Object.keys(bridge.exports).filter((n) => n.startsWith(prefix))) {
    try {
      bridge.exports[name]();
      const leaked = bridge.exports.unreleasedHandles();
      check(name, leaked === 0, `${leaked} unreleased handles`);
    } catch (e) {
      check(name, false, String(e));
    }
  }
  await new Promise((resolve) => setTimeout(resolve));
}

if (failed > 0) {
  console.log(`${failed} failed`);
  process.exit(1);
}
