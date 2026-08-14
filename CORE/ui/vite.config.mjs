export default {
  base: "./",
  esbuild: { jsx: "automatic" },
  build: {
    outDir: "dist",
    emptyOutDir: true,
    sourcemap: false,
    rollupOptions: {
      output: {
        entryFileNames: "assets/app.js",
        assetFileNames: (asset) => asset.name?.endsWith(".css") ? "assets/app.css" : "assets/[name]-[hash][extname]",
      },
    },
  },
};
