defmodule RailWeb.Plugs.CacheBodyReaderTest do
  use Rail.DataCase, async: true

  alias RailWeb.Plugs.CacheBodyReader

  test "read_body/2 caches body on conn.assigns[:raw_body]" do
    conn = Plug.Test.conn(:post, "/test", "raw payload")
    assert {:ok, "raw payload", %Plug.Conn{assigns: %{raw_body: "raw payload"}}} = CacheBodyReader.read_body(conn, [])
  end

  test "read_body/2 accumulates multiple chunks in raw_body" do
    conn =
      :post
      |> Plug.Test.conn("/test", "chunk1")
      |> Plug.Conn.assign(:raw_body, "initial_")

    assert {:ok, "chunk1", %Plug.Conn{assigns: %{raw_body: "initial_chunk1"}}} = CacheBodyReader.read_body(conn, [])
  end

  test "read_body/2 handles :more when body length is capped" do
    conn = Plug.Test.conn(:post, "/test", "helloworld")

    assert {:more, "hello", %Plug.Conn{assigns: %{raw_body: "hello"}}} =
             CacheBodyReader.read_body(conn, length: 5)
  end

  test "read_body/2 returns error tuple on adapter read error" do
    conn = %Plug.Conn{adapter: {RailTest.Mocks.ErrorConnAdapter, nil}}

    assert {:error, :timeout} = CacheBodyReader.read_body(conn, [])
  end
end
