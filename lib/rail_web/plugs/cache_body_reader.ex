defmodule RailWeb.Plugs.CacheBodyReader do
  @moduledoc """
  Custom body reader for `Plug.Parsers` that retains the raw request body on `conn.assigns[:raw_body]`.
  """

  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        prev = conn.assigns[:raw_body] || ""
        {:ok, body, Plug.Conn.assign(conn, :raw_body, prev <> body)}

      {:more, body, conn} ->
        prev = conn.assigns[:raw_body] || ""
        {:more, body, Plug.Conn.assign(conn, :raw_body, prev <> body)}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
