import { gzipSync } from "node:zlib";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";

const wasmPath = new URL("../packages/md4x/build/md4x.wasm", import.meta.url);

const raw = readFileSync(wasmPath);
const gzipped = gzipSync(raw);

function formatSize(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  const kb = bytes / 1000;
  return kb < 100 ? `${kb.toFixed(1)} kB` : `${Math.round(kb)} kB`;
}

const result = {
  size: {
    type: "gzip",
    rawUncompressedSize: raw.byteLength,
    uncompressedSize: formatSize(raw.byteLength),
    rawCompressedSize: gzipped.byteLength,
    compressedSize: formatSize(gzipped.byteLength),
    size: `${formatSize(gzipped.byteLength)} (gzip)`,
  },
};

const badgesDir = new URL("dist/_badges/", import.meta.url);
mkdirSync(badgesDir, { recursive: true });
writeFileSync(new URL("wasm-size.json", badgesDir), JSON.stringify(result));

console.log(`wasm: ${result.size.size} (raw: ${result.size.uncompressedSize})`);
