# Copilot instructions

## Diagrams
- Write architecture diagrams as Mermaid in `docs/*.mmd`, using the Azure icon pack: `azure:<name>`.
  Valid names are listed in `tools/mermaid/icon-index.md` (e.g. `container-apps-environments`, `worker-container-app`,
  `ai-foundry`, `foundry-project`, `firewalls`, `private-endpoints`, `key-vaults`, `container-registries`).
- Prefer `flowchart` with subgraphs and icon shapes
  (`id@{ icon: "azure:firewalls", form: "square", label: "...", pos: "b", h: 48 }`): its layout is deterministic.
  Use `architecture-beta` only for small views (few groups, no edges between nested groups); its automatic layout
  stretches the canvas when edge constraints conflict.
- Render with `node tools/mermaid/render.mjs` and embed the `.svg` in Markdown.

## Infrastructure
- Use Azure Verified Modules (`br/public:avm/...`) pinned to exact versions; add new names to `infra/naming.bicep`.
- Validate with `az bicep build --file infra/main.bicep` and `az bicep build-params --file <file>.bicepparam`.
- Apps are `apps/<name>/main.bicepparam` files using `apps/_shared/container-app.bicep`; never add app resources to `infra/`.

## SRE agents
- Agent behaviour lives in `sre/` (manifests, skills, custom-agent instructions, guard hook); never hard-code it in Bicep.
- Validate with `./scripts/configure-sre-agents.ps1 -DryRun`. New alert rules go in `infra/modules/alerts.bicep`
  (platform) or `apps/_shared/container-app.bicep` (per app); severity decides the owner (Sev0-1 L2, Sev2-4 L1).
