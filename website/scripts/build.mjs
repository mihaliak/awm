import { cp, mkdir, rm, readFile, writeFile, access } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const output = join(root, 'dist');
const socialBanner = join(root, '..', 'docs', 'workspace-hero.png');
const required = ['index.html', 'llms.txt', 'sitemap.xml', 'styles.css', 'bento-system.css', 'product-setup.css', 'hero-variants.css', 'scroll-motion.js', 'scroll-motion.css', 'app.js', 'comparison.js', 'showcase.js', 'showcase.css', 'particles.js', 'app-windows.js', 'app-windows.css', 'feature-loops.js', 'feature-loops.css', 'repository.js', 'site-config.js', 'assets'];

// Check inputs before replacing the previous successful output.
await Promise.all([...required.map(name => join(root, name)), socialBanner].map(file => access(file)));
const page = await readFile(join(root, 'index.html'), 'utf8');
if (!page.includes('data-hero="combined" data-atmosphere="glow"')) {
  throw new Error('Expected the selected glow intro to generate the plain alternative.');
}
const plainPage = page.replace('data-atmosphere="glow"', 'data-atmosphere="plain"');
await rm(output, { recursive: true, force: true });
await mkdir(output, { recursive: true });

for (const name of required) {
  await cp(join(root, name), join(output, name), { recursive: true });
}
await cp(socialBanner, join(output, 'assets', 'workspace-hero.png'));
await writeFile(join(output, 'plain.html'), plainPage);
// Keep both previously shared URLs on the selected introduction.
await writeFile(join(output, 'glow.html'), page);
await writeFile(join(output, 'particles.html'), page);

// On GitHub Pages, connect release links to the app repository automatically.
// Append only the repository override, preserving a configured downloadUrl.
const repositoryUrl = process.env.AWM_REPOSITORY_URL?.trim();
if (repositoryUrl) {
  const parsed = new URL(repositoryUrl);
  if (parsed.protocol !== 'https:' || parsed.username || parsed.password) {
    throw new Error('AWM_REPOSITORY_URL must be an HTTPS URL without credentials.');
  }
  await writeFile(
    join(output, 'site-config.js'),
    `\nwindow.AWM_CONFIG = { ...window.AWM_CONFIG, repositoryUrl: ${JSON.stringify(repositoryUrl.replace(/\/$/, ''))} };\n`,
    { flag: 'a' },
  );
}

await writeFile(join(output, '.nojekyll'), '');
console.log('Glow introduction built in dist/; glow.html and particles.html are aliases, plain.html keeps the alternative.');
