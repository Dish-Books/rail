defmodule Rail.Artifacts.Utils.UrlProbeTest do
  use ExUnit.Case, async: true

  import Rail.Artifacts.Utils.UrlProbe

  describe "probe/2" do
    test "uses custom injected probe function" do
      probe_fn = fn url -> url == "https://allowed.com" end

      assert probe("https://allowed.com", url_probe: probe_fn)
      refute probe("https://other.com", url_probe: probe_fn)
    end

    test "default probe returns true on 200 via Req" do
      req_plug = fn conn ->
        Plug.Conn.send_resp(conn, 200, "OK")
      end

      assert probe("https://example.com", req_options: [plug: req_plug])
    end

    test "default probe returns false on 404" do
      req_plug = fn conn ->
        Plug.Conn.send_resp(conn, 404, "Not Found")
      end

      refute probe("https://example.com/not_found", req_options: [plug: req_plug])
    end

    test "default probe returns false on 410" do
      req_plug = fn conn ->
        Plug.Conn.send_resp(conn, 410, "Gone")
      end

      refute probe("https://example.com/gone", req_options: [plug: req_plug])
    end

    test "default probe falls back to GET on 405 Method Not Allowed" do
      req_plug = fn conn ->
        if conn.method == "HEAD" do
          Plug.Conn.send_resp(conn, 405, "Method Not Allowed")
        else
          Plug.Conn.send_resp(conn, 200, "OK")
        end
      end

      assert probe("https://example.com/no_head", req_options: [plug: req_plug])
    end

    test "default probe returns false when 405 fallback GET returns 404" do
      req_plug = fn conn ->
        if conn.method == "HEAD" do
          Plug.Conn.send_resp(conn, 405, "Method Not Allowed")
        else
          Plug.Conn.send_resp(conn, 404, "Not Found")
        end
      end

      refute probe("https://example.com/no_head_404", req_options: [plug: req_plug])
    end

    test "default probe returns false when 405 fallback GET fails" do
      req_plug = fn conn ->
        if conn.method == "HEAD" do
          Plug.Conn.send_resp(conn, 405, "Method Not Allowed")
        else
          Req.Test.transport_error(conn, :econnrefused)
        end
      end

      refute probe("https://example.com/no_head_err", req_options: [plug: req_plug])
    end

    test "default probe returns false on transport error" do
      req_plug = fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end

      refute probe("https://example.com/timeout", req_options: [plug: req_plug])
    end
  end
end
