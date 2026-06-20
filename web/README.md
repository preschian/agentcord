# AgentCord landing page

The marketing site for [AgentCord](https://github.com/preschian/agentcord), the macOS menu bar app that shows your Claude Code session as a Discord Rich Presence. It's a single Astro page deployed to Cloudflare Workers, live at [agentcord.avalix.dev](https://agentcord.avalix.dev).

## Project structure

```text
/
├── public/                 # static assets (icons, og-image, AgentCord.dmg)
├── src/
│   └── pages/
│       └── index.astro     # the whole landing page
├── astro.config.mjs        # site URL + Cloudflare adapter + sitemap
└── wrangler.jsonc          # Cloudflare Workers config
```

The page is a single `index.astro` file with inline styles and a small client script that animates the Discord presence demo. The downloadable `AgentCord.dmg` ships from `public/`.

## Commands

Run these from the `web/` directory:

| Command                | Action                                          |
| :--------------------- | :---------------------------------------------- |
| `bun install`          | Install dependencies                            |
| `bun run dev`          | Start the dev server at `localhost:4321`        |
| `bun run build`        | Build the production site to `./dist/`          |
| `bun run preview`      | Build, then serve the Worker locally with `wrangler dev` |
| `bun run deploy`       | Build and deploy to Cloudflare Workers          |
| `bun run generate-types` | Generate Worker types with `wrangler types`   |

## Deployment

`bun run deploy` builds the static site and pushes it to Cloudflare Workers under the `agentcord` Worker (see `wrangler.jsonc`). You need access to the Cloudflare account and to be logged in with `wrangler login` first.
