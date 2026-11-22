import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  define: { "process.env.NODE_ENV": JSON.stringify("production") },
  build: {
    lib: { entry: "src/embed.tsx", name: "GpuVMEmbed", formats: ["iife"], fileName: () => "embed.js" },
    outDir: "../site/assets",
    emptyOutDir: false,
    publicDir: false,
    assetsInlineLimit: 200_000,
  },
});
