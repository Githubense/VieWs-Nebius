import { Config } from "@remotion/cli/config";

// Use standard macOS Google Chrome binary for fast, reliable hardware-accelerated rendering
Config.setBrowserExecutable(
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
);

// High quality video settings
Config.setVideoImageFormat("jpeg");
Config.setJpegQuality(95);
Config.setPixelFormat("yuv420p");
Config.setCodec("h264");
