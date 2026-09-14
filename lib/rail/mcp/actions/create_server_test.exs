defmodule Rail.Mcp.Actions.CreateServerTest do
  use Rail.DataCase, async: true

  alias Rail.Mcp
  alias Rail.Mcp.Schemas.McpServer

  test "creates a server that starts enabled and undiscovered" do
    assert {:ok, %McpServer{name: "cs_linear", auth: :oauth, enabled: true, client_id: nil, tools: []}} =
             Mcp.create_server(system_scope(), %{name: "cs_linear", url: "https://mcp.linear.app/mcp"})
  end

  test "validates name, url and uniqueness" do
    assert {:error, changeset} =
             Mcp.create_server(system_scope(), %{name: "Bad-Slug", url: "ftp://nope"})

    assert %{name: ["must be lowercase letters, digits and underscores"], url: ["must be an http(s) URL"]} =
             errors_on(changeset)

    assert {:error, changeset} = Mcp.create_server(system_scope(), %{name: "a__b", url: "https://x.io"})
    assert %{name: ["must not contain a double underscore"]} = errors_on(changeset)

    assert {:ok, _server} = Mcp.create_server(system_scope(), %{name: "cs_dup", url: "https://x.io"})
    assert {:error, changeset} = Mcp.create_server(system_scope(), %{name: "cs_dup", url: "https://y.io"})
    assert %{name: ["has already been taken"]} = errors_on(changeset)
  end

  test "is admin only" do
    assert {:error, :not_authorized} =
             Mcp.create_server(user_scope(), %{name: "cs_linear", url: "https://mcp.linear.app/mcp"})
  end
end
