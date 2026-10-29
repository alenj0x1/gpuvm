// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import starlightLinksValidator from 'starlight-links-validator';

export default defineConfig({
  site: 'https://alenj0x1.github.io',
  base: '/gpuvm/docs',
  integrations: [
    starlight({
      title: 'GpuVM',
      description: 'Windows VMs that use your GPU with Hyper-V GPU partitioning, streamed with Sunshine and Moonlight.',
      logo: { src: './src/assets/logo.svg', alt: 'GpuVM' },
      favicon: '/favicon.svg',
      defaultLocale: 'root',
      locales: {
        root: { label: 'English', lang: 'en' },
        es: { label: 'Español', lang: 'es' },
      },
      social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/alenj0x1/gpuvm' }],
      editLink: { baseUrl: 'https://github.com/alenj0x1/gpuvm/edit/main/docs/' },
      customCss: ['@fontsource/plus-jakarta-sans/400.css', '@fontsource/plus-jakarta-sans/600.css', '@fontsource/plus-jakarta-sans/700.css', './src/styles/custom.css'],
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
          items: ['using-the-app', 'streaming', 'profiles', 'labs'],
        },
        {
          label: 'Reference',
          translations: { es: 'Referencia' },
          items: ['cli', 'architecture', 'troubleshooting', 'changelog'],
        },
      ],
    }),
  ],
});
