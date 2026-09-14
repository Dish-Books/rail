defmodule Rail.Mcp.Actions.AuthorizeUrlTest do
  use ExUnit.Case, async: true

  alias Rail.Mcp
  alias Rail.Mcp.Schemas.McpServer

  test "builds a PKCE authorization URL for the server's resource and scopes" do
    server = %McpServer{
      url: "https://mcp.example.com/mcp",
      resource: "https://mcp.example.com/",
      authorization_endpoint: "https://auth.example.com/authorize",
      client_id: "client_1",
      scopes: ["read", "write"]
    }

    assert {:ok, url, verifier} = Mcp.authorize_url(server, "state_1")
    challenge = :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)
    redirect_uri = RailWeb.Endpoint.url() <> "/auth/mcp/callback"

    assert %URI{host: "auth.example.com", path: "/authorize", query: query} = URI.parse(url)

    assert %{
             "response_type" => "code",
             "client_id" => "client_1",
             "redirect_uri" => ^redirect_uri,
             "code_challenge" => ^challenge,
             "code_challenge_method" => "S256",
             "state" => "state_1",
             "resource" => "https://mcp.example.com/",
             "scope" => "read write"
           } = URI.decode_query(query)
  end

  test "keeps an endpoint's own query and leaves out scope and resource defaults" do
    server = %McpServer{
      url: "https://mcp.example.com/mcp",
      authorization_endpoint: "https://auth.example.com/authorize?tenant=t1",
      client_id: "client_1",
      scopes: []
    }

    assert {:ok, url, _verifier} = Mcp.authorize_url(server, "state_1")
    assert %URI{query: query} = URI.parse(url)
    params = URI.decode_query(query)

    assert %{"tenant" => "t1", "resource" => "https://mcp.example.com/mcp"} = params
    refute Map.has_key?(params, "scope")
  end

  test "refuses a server that was never discovered" do
    assert {:error, :not_discovered} = Mcp.authorize_url(%McpServer{url: "https://mcp.example.com/mcp"}, "state_1")
  end
end
