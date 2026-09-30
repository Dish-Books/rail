defmodule RailWeb.EndpointTest do
  use RailWeb.ConnCase, async: true

  # prod.exs sets cache_static_manifest, so ~p links each icon under the name phx.digest gives it.
  test "serves every icon under the digested name production links", %{conn: conn} do
    static = Application.app_dir(:rail, "priv/static")

    for file <- ["favicon.svg", "favicon.ico", "apple-touch-icon.png"] do
      body = File.read!(Path.join(static, file))
      digest = body |> :erlang.md5() |> Base.encode16(case: :lower)
      digested = "#{Path.rootname(file)}-#{digest}#{Path.extname(file)}"

      on_exit(fn -> File.rm(Path.join(static, digested)) end)
      File.cp!(Path.join(static, file), Path.join(static, digested))

      assert ^body = conn |> get("/" <> digested) |> response(200)
    end
  end
end
