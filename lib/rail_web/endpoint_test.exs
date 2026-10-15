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

  # A sandboxed frame or a file:// screenshot has no origin, and fonts load only with CORS.
  test "serves the design kit to any origin, and Rail's own assets to none", %{conn: conn} do
    static = Application.app_dir(:rail, "priv/static")
    name = "endpoint-test-#{System.unique_integer([:positive])}.css"
    kit_file = Path.join([static, "design-kit", name])
    asset_file = Path.join([static, "assets", name])

    for path <- [kit_file, asset_file] do
      File.mkdir_p!(Path.dirname(path))
      on_exit(fn -> File.rm(path) end)
      File.write!(path, ".ph { line-height: 1; }")
    end

    kit_conn = get(conn, "/design-kit/" <> name)
    assert ".ph { line-height: 1; }" = response(kit_conn, 200)
    assert ["*"] = get_resp_header(kit_conn, "access-control-allow-origin")

    asset_conn = get(build_conn(), "/assets/" <> name)
    assert ".ph { line-height: 1; }" = response(asset_conn, 200)
    assert [] = get_resp_header(asset_conn, "access-control-allow-origin")
  end
end
