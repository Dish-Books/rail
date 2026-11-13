defmodule Rail.Mcp do
  @moduledoc """
  Public context for MCP: the global list of remote servers, each user's OAuth connection to them, the proxy agents
  reach them through at `/mcp/internal`, and the OAuth server that lets a person's own Claude reach Rail at `/mcp`.

  Agents never hold an upstream token. Each spawned turn carries a run token that authenticates it to `/mcp/internal`;
  the proxy lists and forwards only the tools its role allows, on the connection of the issue's assigned user.
  """

  use Rail.PermissionsDecorator

  alias Rail.Mcp.Actions

  defdelegate list_servers(), to: Actions.ListServers
  defdelegate get_server(by), to: Actions.GetServer

  @decorate can?(resource: :mcp_servers, action: :manage)
  defdelegate create_server(scope, attrs), to: Actions.CreateServer

  @decorate can?(resource: :mcp_servers, action: :manage)
  defdelegate update_server(scope, server, attrs), to: Actions.UpdateServer

  @decorate can?(resource: :mcp_servers, action: :manage)
  defdelegate delete_server(scope, server), to: Actions.DeleteServer

  @decorate can?(resource: :mcp_servers, action: :manage)
  defdelegate discover_server(scope, server), to: Actions.DiscoverServer

  @decorate can?(resource: :mcp_servers, action: :manage)
  defdelegate refresh_server_tools(scope, server), to: Actions.RefreshServerTools

  defdelegate authorize_url(server, state), to: Actions.AuthorizeUrl
  defdelegate connect_server(scope, server, code, verifier), to: Actions.ConnectServer
  defdelegate disconnect_server(scope, server), to: Actions.DisconnectServer
  defdelegate list_connections(scope), to: Actions.ListConnections
  defdelegate mcp_token(user, server, opts \\ []), to: Actions.McpToken

  defdelegate issue_run_token(), to: Actions.IssueRunToken
  defdelegate authenticate_run_token(token), to: Actions.AuthenticateRunToken
  defdelegate list_run_tools(context), to: Actions.ListRunTools
  defdelegate check_run_tools(context), to: Actions.CheckRunTools
  defdelegate call_run_tool(context, name, arguments), to: Actions.CallRunTool

  defdelegate register_dynamic_client(metadata), to: Actions.RegisterDynamicClient
  defdelegate validate_authorize_request(params), to: Actions.ValidateAuthorizeRequest
  defdelegate authorize(scope, params), to: Actions.Authorize
  defdelegate authenticate_client(client_id, credential), to: Actions.AuthenticateClient
  defdelegate exchange_code(client, params), to: Actions.ExchangeCode
  defdelegate refresh_token(client, params), to: Actions.RefreshToken
  defdelegate resolve_access_token(plaintext), to: Actions.ResolveAccessToken
  defdelegate list_authorizations(scope), to: Actions.ListAuthorizations
  defdelegate revoke_authorization(scope, family_id), to: Actions.RevokeAuthorization
end
