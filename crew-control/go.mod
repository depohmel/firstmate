// A read-only HTTP MCP server living in the firstmate fork that exposes
// fleet/crew state to MCP clients without requiring a terminal.
//
// It wraps firstmate's fleet scripts (fm-fleet-view.sh, fm-crew-state.sh)
// and data/backlog.md, exposing three tools: fleet_overview, crew_state,
// and backlog. All three are read-only — no crew is started, stopped,
// steered, or torn down.
//
// See README.md for deployment and config.
module github.com/depohmel/firstmate/crew-control

go 1.26.0

require github.com/mark3labs/mcp-go v0.57.0

require (
	github.com/google/jsonschema-go v0.4.2 // indirect
	github.com/google/uuid v1.6.0 // indirect
	github.com/santhosh-tekuri/jsonschema/v6 v6.0.2 // indirect
	github.com/spf13/cast v1.7.1 // indirect
	github.com/yosida95/uritemplate/v3 v3.0.2 // indirect
	golang.org/x/text v0.14.0 // indirect
)
