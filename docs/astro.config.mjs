// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import starlightLinksValidator from 'starlight-links-validator';

export default defineConfig({
  site: 'https://gpuvm.alenj.dev',
  base: '/docs',
  integrations: [
    starlight({
      title: 'gpuvm',
      description: 'Windows VMs that use your GPU with Hyper-V GPU partitioning, streamed to GpuVM's own viewer, and usable by AI agents.',
      logo: { src: './src/assets/logo.svg', alt: 'GpuVM' },
      favicon: '/favicon.svg',
      defaultLocale: 'root',
      locales: {
        root: { label: 'English', lang: 'en' },
        es: { label: 'Español', lang: 'es' },
      },
      social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/alenj0x1/gpuvm' }],
      editLink: { baseUrl: 'https://github.com/alenj0x1/gpuvm/edit/main/docs/' },
      customCss: ['@fontsource/plus-jakarta-sans/400.css', '@fontsource/plus-jakarta-sans/500.css', '@fontsource/plus-jakarta-sans/600.css', '@fontsource/plus-jakarta-sans/700.css', './src/styles/custom.css'],
      // Code blocks in the app's tones: one rounded piece, no border or shadow, the title bar a step off the code.
      expressiveCode: {
        themes: ['github-dark-default', 'github-light-default'],
        styleOverrides: {
          borderRadius: '14px',
          borderColor: 'transparent',
          codeBackground: 'var(--gv-surface)',
          codePaddingBlock: '1rem',
          codePaddingInline: '1.25rem',
          uiFontFamily: 'var(--sl-font)',
          frames: {
            frameBoxShadowCssValue: 'none',
            editorTabBarBackground: 'var(--gv-code-bar)',
            editorActiveTabBackground: 'var(--gv-code-bar)',
            editorActiveTabBorderColor: 'transparent',
            editorActiveTabIndicatorTopColor: 'transparent',
            editorActiveTabIndicatorBottomColor: 'transparent',
            editorTabBarBorderBottomColor: 'transparent',
            editorActiveTabForeground: 'var(--gv-muted)',
            terminalBackground: 'var(--gv-surface)',
            terminalTitlebarBackground: 'var(--gv-code-bar)',
            terminalTitlebarBorderBottomColor: 'transparent',
            terminalTitlebarForeground: 'var(--gv-muted)',
            terminalTitlebarDotsForeground: 'var(--gv-faint)',
            terminalTitlebarDotsOpacity: '0.5',
            inlineButtonBackground: 'var(--gv-hover)',
            inlineButtonForeground: 'var(--gv-muted)',
            inlineButtonBorder: 'transparent',
            tooltipSuccessBackground: 'var(--gv-ok)',
          },
        },
      },
      plugins: [starlightLinksValidator()],
      sidebar: [
        {
          label: 'Start here',
          translations: { es: 'Empieza aquí' },
          items: ['index', 'requirements', 'install'],
        },
        {
          label: 'Guides',
          translations: { es: 'Guías' },
          items: ['using-the-app', 'agents', 'streaming', 'profiles'],
        },
        {
          label: 'Reference',
          translations: { es: 'Referencia' },
          items: ['cli', 'architecture', 'troubleshooting', 'changelog'],
        },
        {
          label: 'Development',
          translations: { es: 'Desarrollo' },
          items: ['labs'],
        },
      ],
    }),
  ],
});
