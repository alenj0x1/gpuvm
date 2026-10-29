// Builds the app's real components for the website (src/embed.tsx) into one script: site/assets/embed.js.
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  define: { "process.env.NODE_ENV": JSON.stringify("production") },
  build: {
    lib: { entry: "src/embed.tsx", name: "GpuVMEmbed", formats: ["iife"], fileName: () => "embed.js" },
    outDir: "../site/assets",
    emptyOutDir: false,
    // App icons and fonts inline into the script, so the demo is one file.
    assetsInlineLimit: 200_000,
  },
});
