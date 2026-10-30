import { bundle } from "@remotion/bundler";
import { renderStill, selectComposition } from "@remotion/renderer";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

async function main() {
  console.log("Bundling...");
  const bundleLocation = await bundle({
    entryPoint: path.resolve(__dirname, "src/index.ts"),
    publicDir: path.resolve(__dirname, "public"),
  });
  console.log("Bundle created at:", bundleLocation);

  console.log("Selecting composition...");
  const comp = await selectComposition({
    serveUrl: bundleLocation,
    id: "ViewsShowcase",
    browserExecutable: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    onBrowserLog: (log) => {
      console.log(`[Browser ${log.type}] ${log.text}`);
    },
  });
  console.log("Found composition:", comp.id, "fps:", comp.fps);

  console.log("Rendering still frame 0...");
  await renderStill({
    composition: comp,
    serveUrl: bundleLocation,
    output: path.resolve(__dirname, "out/test_frame_0.png"),
    frame: 0,
    browserExecutable: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    onBrowserLog: (log) => {
      console.log(`[Browser ${log.type}] ${log.text}`);
    },
  });
  console.log("Successfully rendered to out/test_frame_0.png!");
}

main().catch((err) => {
  console.error("Diagnostic error:", err);
  process.exit(1);
});
