defmodule RailWeb.Components.HostStatusTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Tools.Schemas.SandboxHost
  alias RailWeb.Components.HostStatus

  @host %SandboxHost{id: "hst_1", name: "fsn1-ax102-sandboxes-03", ssh_address: "rail@10.0.4.13:2222"}
  @since ~U[2026-10-10 14:12:00Z]

  test "reads Connected, with nothing under it" do
    html = render_component(&HostStatus.host_status/1, id: "s", status: %{state: :connected, error: nil, host: @host})
    assert html =~ "Connected"
    refute html =~ ~s(id="s-detail")
  end

  test "a host that never connected asks for its key on the host, but not when the line is left out" do
    status = %{state: :never_connected, error: :permission_denied, host: @host}
    html = render_component(&HostStatus.host_status/1, id: "s", status: status)
    assert html =~ "Not connected yet"
    assert html =~ "Add its key to the host"
    refute html =~ "Permission denied"

    refute render_component(&HostStatus.host_status/1, id: "s", status: status, line: false) =~ "Add its key"
  end

  test "an unreachable host reads since when, with SSH's error in words" do
    for {error, words} <- [
          {:host_key_changed, "Host key changed"},
          {:permission_denied, "Permission denied (publickey). Is Rail&#39;s key in authorized_keys?"},
          {:timeout, "Connection timed out on 10.0.4.13 port 2222."},
          {:econnrefused, "Connection refused on 10.0.4.13 port 2222."},
          {:connection_lost, "Connection lost"},
          {:nxdomain, "Non-existing domain on 10.0.4.13 port 2222."},
          {"Key exchange failed", "Key exchange failed"}
        ] do
      status = %{state: :unreachable, since: @since, error: error, host: @host}
      html = render_component(&HostStatus.host_status/1, id: "s", status: status)

      assert html =~ "Unreachable since"
      assert html =~ ~s(datetime="2026-10-10T14:12:00Z")
      assert html =~ words
    end
  end

  test "reads Connecting while a connection starts again, and Inactive under the local runtime" do
    assert render_component(&HostStatus.host_status/1, id: "s", status: %{state: :connecting, error: nil, host: @host}) =~
             "Connecting"

    html = render_component(&HostStatus.host_status/1, id: "s", status: %{state: :inactive, error: nil, host: @host})
    assert html =~ "Inactive"
    assert html =~ "Sandboxes run on Rail&#39;s machine"
  end
end
