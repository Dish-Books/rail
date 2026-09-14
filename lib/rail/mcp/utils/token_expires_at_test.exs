defmodule Rail.Mcp.Utils.TokenExpiresAtTest do
  use ExUnit.Case, async: true

  import Rail.Mcp.Utils.TokenExpiresAt

  test "turns expires_in into a time, or nil when absent" do
    assert %DateTime{} = expires_at = token_expires_at(%{"expires_in" => 3600})
    assert DateTime.diff(expires_at, DateTime.utc_now()) in 3590..3600
    assert nil == token_expires_at(%{"expires_in" => "soon"})
    assert nil == token_expires_at(%{})
  end
end
