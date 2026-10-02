# Sway website

A dependency-free, responsive showcase for Sway, made for 0x1p0. The app source and release pipelines are unchanged.

Live: https://sway-application.vercel.app/

## Local preview

From this directory, run `python3 -m http.server 4173 --bind 127.0.0.1`, then open `http://127.0.0.1:4173`.

## Checks

Run `node --test tests/*.test.mjs`. Test both native preview sliders with a mouse, touch, and arrow keys. Check 390 px and desktop layouts, expanded details, and reduced-motion preferences.

## Deployment

Deploy **this directory**, not the repository root: `vercel --prod`. Local project metadata is ignored by Git. No build command, runtime dependencies, environment variables, or tokens are required by the site.

The Vercel project is `sway-application`. Deployments currently use the authenticated CLI, not an automatic Git deployment hook. After pushing site changes, run `cd website && vercel --prod` from the repository root. Never upload local `.env*` files; `.vercelignore` excludes them.

Download links fall back to the verified v1.0.14 DMG. A single public GitHub API request updates them to the latest stable universal DMG, after validating the exact repository, tag, filename, and URL. API failures leave the fallback intact. Refresh the static fallback when appropriate. The website does not install or launch Sway.

The app icon is reused from Sway’s existing assets. Fonts are local system fonts; no remote fonts, analytics, ads, or persistent browser storage are used. Hosting and the public GitHub release request still expose ordinary connection metadata to those providers.
