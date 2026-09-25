import { defineConfig } from 'tsdown'
export default defineConfig({entry: {index: 'src/dsh-notch.ts'}, format:'esm', target:'node24', outDir:'lib', deps:{neverBundle:[/^@deepseek-ai\//]}, dts:false, sourcemap:true})
