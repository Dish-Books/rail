# Backends

Owns CLI agent backend accounts (`Rail.Backends.Schemas.CliAccount`), usage probes (`ClaudeUsageProbe`, `AgyUsageProbe`), model registry discovery and fallbacks (`ModelRegistry`), and single-flighted scheduled quota refreshes (`RefreshServer`).

## Language

**CLI Account**:
A local machine record tracking a coding agent CLI installation (`:claude` or `:agy`), its status (`"not_configured"`, `"signed_out"`, `"unavailable"`, or `"ready"`), account email, subscription tier, and current quota utilization groups.

**Usage Probe**:
An isolated, non-throwing check querying local CLI binaries and cached configuration files to discover quota utilization and authentication status.

**Model Registry**:
A central catalog of available AI models for each CLI backend, discovered dynamically from tool outputs or binary inspection, falling back to validated default aliases.

**Refresh Server**:
A GenServer managing periodic 15-minute quota polling and single-flighting concurrent refresh requests across the application.

## Relationships

- **Backends → ToolEnv**: Resolves executable paths on the login shell PATH and executes timeout-governed CLI commands.
- **Backends → PubSub**: Broadcasts on `"backends:usage_updated"` whenever usage figures are refreshed.
- **Backends → Roles**: Provides available models and backend options when configuring project agent roles.
