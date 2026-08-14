import { bench, compact, run, summary } from "mitata";
import * as napi from "../lib/napi.mjs";
import * as wasm from "../lib/wasm/default.mjs";
import * as jsYaml from "js-yaml";
import YAML from "yaml";
import { parseYAML as confboxParseYAML } from "confbox";
import * as fixtures from "./_fixtures.mjs";

await wasm.init();
await napi.init();

const inputs = {
  small: fixtures.yamlSmall,
  medium: fixtures.yamlMedium,
  large: fixtures.yamlLarge,
};

// Parity gate: a parser that drops or mis-coerces nodes would otherwise show up
// as a win. Bail loudly rather than publish numbers for different work.
const parsers = {
  "md4x.napi": (input) => napi.parseYAML(input),
  "md4x.wasm": (input) => wasm.parseYAML(input),
  "js-yaml": (input) => jsYaml.load(input),
  yaml: (input) => YAML.parse(input),
  confbox: (input) => confboxParseYAML(input),
};

for (const [name, input] of Object.entries(inputs)) {
  const expected = JSON.stringify(jsYaml.load(input));
  for (const [parser, parse] of Object.entries(parsers)) {
    const actual = JSON.stringify(parse(input));
    if (actual !== expected) {
      throw new Error(
        `${parser} disagrees with js-yaml on the ${name} fixture:\n  ${actual}\n  ${expected}`,
      );
    }
  }
}

for (const [name, input] of Object.entries(inputs)) {
  compact(() => {
    // Full parse: YAML text in, materialized JS value out.
    summary(() => {
      for (const [parser, parse] of Object.entries(parsers)) {
        bench(`${parser} (parseYAML) (${name})`, () => parse(input));
      }
    });

    // md4x's native shape is a JSON string; `parseYAML` is that plus a
    // `JSON.parse`. Bench it against the JS libs' nearest equivalent (parse
    // then re-serialize) to show where the time actually goes.
    summary(() => {
      bench(`md4x.napi (yamlToJson) (${name})`, () => napi.yamlToJson(input));
      bench(`md4x.wasm (yamlToJson) (${name})`, () => wasm.yamlToJson(input));
      bench(`js-yaml (yamlToJson) (${name})`, () =>
        JSON.stringify(jsYaml.load(input)),
      );
      bench(`yaml (yamlToJson) (${name})`, () =>
        JSON.stringify(YAML.parse(input)),
      );
    });
  });
}

await run();
