defmodule RailWeb.Components.HostStatus do
  @moduledoc """
  A host's connection as a badge, and, with `line`, the line under it that says
  what to do or what SSH said.
  """
  use RailWeb, :html

  alias Rail.Tools.Schemas.SandboxHost

  attr :id, :string, required: true
  attr :status, :map, required: true, doc: "one of `Rail.Tools.list_sandbox_host_statuses/0`"
  attr :line, :boolean, default: true

  def host_status(assigns) do
    %{state: state, error: error, host: host} = assigns.status
    {icon, label, tone} = badge(state)

    assigns =
      assigns
      |> assign(:icon, icon)
      |> assign(:label, label)
      |> assign(:tone, tone)
      |> assign(:since, if(state == :unreachable, do: assigns.status.since))
      |> assign(:detail, assigns.line && detail(state, error, host))

    ~H"""
    <span
      id={@id}
      class={["inline-flex max-w-full items-start gap-1.5 text-xs font-semibold", @tone]}
    >
      <.icon name={@icon} class="mt-px size-3.5" />
      <%!-- The viewer's clock can run long, so the time wraps under the label rather than being cut off. --%>
      <span>
        {@label}
        <.local_time :if={@since} id={"#{@id}-since"} at={@since} class="whitespace-nowrap" />
      </span>
    </span>
    <p
      :if={@detail}
      id={"#{@id}-detail"}
      class="mt-0.5 text-xs text-slate-500 dark:text-slate-400 truncate"
      title={@detail}
    >
      {@detail}
    </p>
    """
  end

  defp badge(:connected), do: {"pi-check-circle", "Connected", "text-emerald-600 dark:text-emerald-400"}
  defp badge(:never_connected), do: {"pi-key", "Not connected yet", "text-amber-700 dark:text-amber-300"}
  defp badge(:unreachable), do: {"pi-plugs", "Unreachable since", "text-red-600 dark:text-red-400"}
  defp badge(:connecting), do: {"pi-arrows-clockwise", "Connecting", "text-slate-600 dark:text-slate-300"}
  defp badge(:inactive), do: {"pi-pause-circle", "Inactive", "text-slate-600 dark:text-slate-300"}

  defp detail(:never_connected, _error, _host), do: "Add its key to the host"
  defp detail(:inactive, _error, _host), do: "Sandboxes run on Rail's machine"
  defp detail(:unreachable, error, %SandboxHost{} = host), do: error_text(error, SandboxHost.ssh_target(host))
  defp detail(_connected_or_connecting, _error, _host), do: nil

  defp error_text(:host_key_changed, _target), do: "Host key changed"
  defp error_text(:permission_denied, _target), do: "Permission denied (publickey). Is Rail's key in authorized_keys?"
  defp error_text(:connection_lost, _target), do: "Connection lost"
  defp error_text(:timeout, {_user, host, port}), do: "Connection timed out on #{host} port #{port}."
  defp error_text(:econnrefused, {_user, host, port}), do: "Connection refused on #{host} port #{port}."

  defp error_text(reason, {_user, host, port}) when is_atom(reason),
    do: "#{String.capitalize(to_string(:inet.format_error(reason)))} on #{host} port #{port}."

  defp error_text("" <> message, _target), do: message
end
