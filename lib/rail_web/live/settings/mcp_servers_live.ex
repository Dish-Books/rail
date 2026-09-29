defmodule RailWeb.Settings.McpServersLive do
  @moduledoc false
  use RailWeb, :live_view

  alias Rail.Mcp

  @empty_form %{"name" => "", "url" => ""}

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "MCP Servers")
      |> assign(:current_section, :mcp_servers)
      |> assign(:servers, Mcp.list_servers())
      |> assign(:show_modal, false)
      |> assign(:form, @empty_form)
      |> assign(:form_errors, %{})

    {:ok, socket}
  end

  def handle_params(_params, _uri, socket) do
    socket =
      socket
      |> assign(:page_title, "MCP Servers")
      |> assign(:current_section, :mcp_servers)

    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_section={@current_section}
      current_scope={@current_scope}
      is_rail_extended={@is_rail_extended}
      attention_count={@attention_count}
      triage_count={@triage_count}
      current_project_id={@current_project_id}
      projects={@projects}
      theme={@theme}
      show_project_switcher={@show_project_switcher}
    >
      <div
        class="max-w-[90rem] mx-auto py-10 px-4 sm:px-6 lg:px-8 space-y-10"
        id="mcp-servers-settings"
      >
        <div>
          <h1 class="text-2xl font-bold tracking-tight text-slate-900 dark:text-slate-100">
            MCP Servers
          </h1>
          <p class="mt-1 text-sm text-slate-500 dark:text-slate-400">
            Manage the remote MCP servers agents reach through Rail.
          </p>
        </div>

        <.settings_nav current_scope={@current_scope} active_tab={:mcp_servers} />

        <div class="flex items-center justify-between">
          <div>
            <h2 class="text-lg font-medium text-slate-900 dark:text-slate-100">
              Registered Servers
            </h2>
            <p class="text-xs text-slate-500 dark:text-slate-400">
              Users connect their own accounts; roles choose which tools agents may call.
            </p>
          </div>
          <button
            type="button"
            phx-click="new_server"
            id="new-server-button"
            class="rounded-md bg-indigo-600 px-3 py-2 text-sm font-semibold text-white shadow-sm hover:bg-indigo-500 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-indigo-600"
          >
            New Server
          </button>
        </div>

        <section
          class="bg-slate-50 dark:bg-slate-800 shadow rounded-lg border border-slate-200 dark:border-slate-700 overflow-hidden"
          id="mcp-servers-list-section"
        >
          <div
            :if={Enum.empty?(@servers)}
            class="p-8 text-center text-slate-500 dark:text-slate-400 text-sm"
            id="mcp-servers-empty"
          >
            No MCP servers registered yet. Click "New Server" to add one.
          </div>

          <ul
            :if={not Enum.empty?(@servers)}
            role="list"
            class="divide-y divide-slate-200 dark:divide-slate-700"
            id="mcp-servers-list"
          >
            <li
              :for={server <- @servers}
              class="p-6 flex items-center justify-between gap-4 hover:bg-slate-100 dark:hover:bg-slate-700"
              id={"mcp-server-#{server.name}"}
            >
              <div class="space-y-1 min-w-0">
                <div class="flex items-center space-x-3">
                  <span class="text-base font-semibold font-mono text-slate-900 dark:text-slate-100">
                    {server.name}
                  </span>
                  <span class={status_class(server)} id={"mcp-server-status-#{server.name}"}>
                    {status_label(server)}
                  </span>
                  <span
                    :if={!server.enabled}
                    class="inline-flex items-center rounded-md bg-slate-100 dark:bg-slate-700 px-2 py-1 text-xs font-medium text-slate-500 dark:text-slate-400 ring-1 ring-inset ring-zinc-500/20"
                    id={"mcp-server-disabled-#{server.name}"}
                  >
                    Disabled
                  </span>
                </div>
                <div class="flex items-center space-x-4 text-xs text-slate-500 dark:text-slate-400">
                  <span class="truncate">
                    URL:
                    <span class="font-mono text-slate-900 dark:text-slate-100">{server.url}</span>
                  </span>
                  <span>•</span>
                  <span id={"mcp-server-tools-#{server.name}"}>
                    Tools:
                    <span class="font-semibold text-slate-900 dark:text-slate-100">{length(
                      server.tools
                    )}</span>
                  </span>
                </div>
              </div>

              <div class="flex shrink-0 items-center gap-2">
                <.button
                  size="sm"
                  phx-click="discover"
                  phx-value-id={server.id}
                  id={"discover-#{server.name}"}
                >
                  <.icon name="pi-magnifying-glass" class="h-3.5 w-3.5" /> Discover
                </.button>
                <.button
                  size="sm"
                  phx-click="refresh_tools"
                  phx-value-id={server.id}
                  id={"refresh-tools-#{server.name}"}
                >
                  <.icon name="pi-arrows-clockwise" class="h-3.5 w-3.5" /> Refresh Tools
                </.button>
                <.button
                  size="sm"
                  phx-click="toggle_enabled"
                  phx-value-id={server.id}
                  id={"toggle-#{server.name}"}
                >
                  {if server.enabled, do: "Disable", else: "Enable"}
                </.button>
                <.button
                  size="sm"
                  variant="danger"
                  phx-click="delete"
                  phx-value-id={server.id}
                  data-confirm={"Delete #{server.name}? Every user's connection to it goes too."}
                  id={"delete-#{server.name}"}
                >
                  <.icon name="pi-trash" class="h-3.5 w-3.5" /> Delete
                </.button>
              </div>
            </li>
          </ul>
        </section>

        <div
          :if={@show_modal}
          class="fixed inset-0 z-50 flex items-center justify-center bg-zinc-900/50 p-4"
          id="mcp-server-modal"
        >
          <div class="w-full max-w-xl rounded-lg bg-slate-50 dark:bg-slate-800 p-6 shadow-xl space-y-6">
            <div class="flex items-center justify-between border-b border-slate-200 dark:border-slate-700 pb-4">
              <h2 class="text-lg font-semibold text-slate-900 dark:text-slate-100" id="modal-title">
                New MCP Server
              </h2>
              <button
                type="button"
                phx-click="close_modal"
                id="close-modal-button"
                class="text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100 font-bold"
              >
                ✕
              </button>
            </div>

            <form
              id="mcp-server-form"
              phx-change="validate"
              phx-submit="create_server"
              class="space-y-4"
            >
              <div>
                <.input
                  label="Name"
                  name="server[name]"
                  id="mcp-server-name"
                  value={@form["name"]}
                  placeholder="linear"
                  class="font-mono"
                  errors={List.wrap(@form_errors[:name])}
                />
                <p class="mt-1.5 text-xs text-slate-500 dark:text-slate-400">
                  Also the prefix agents see on its tools, e.g. <span class="font-mono">linear__get_issue</span>.
                </p>
              </div>

              <.input
                type="url"
                label="URL"
                name="server[url]"
                id="mcp-server-url"
                value={@form["url"]}
                placeholder="https://mcp.linear.app/mcp"
                class="font-mono"
                errors={List.wrap(@form_errors[:url])}
              />

              <div class="flex items-center justify-end space-x-3 pt-4 border-t border-slate-200 dark:border-slate-700">
                <.button type="button" phx-click="close_modal" id="cancel-server-button">
                  Cancel
                </.button>
                <.button variant="primary" type="submit" id="add-mcp-server-button">
                  Add Server
                </.button>
              </div>
            </form>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  def handle_event("new_server", _params, socket) do
    socket =
      socket
      |> assign(:show_modal, true)
      |> assign(:form, @empty_form)
      |> assign(:form_errors, %{})

    {:noreply, socket}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, assign(socket, :show_modal, false)}
  end

  def handle_event("validate", %{"server" => params}, socket) do
    {:noreply, assign(socket, :form, params)}
  end

  def handle_event("create_server", %{"server" => params}, socket) do
    scope = socket.assigns.current_scope
    attrs = Map.new(params, fn {key, value} -> {key, String.trim(value)} end)

    case Mcp.create_server(scope, attrs) do
      {:ok, server} ->
        socket =
          socket
          |> assign(:show_modal, false)
          |> assign(:form, @empty_form)
          |> assign(:form_errors, %{})
          |> discover(scope, server)

        {:noreply, socket}

      {:error, changeset} ->
        errors = Map.new(changeset.errors, fn {field, {message, _opts}} -> {field, message} end)

        socket =
          socket
          |> assign(:form, attrs)
          |> assign(:form_errors, errors)

        {:noreply, socket}
    end
  end

  def handle_event("discover", %{"id" => id}, socket) do
    with_server(socket, id, &discover(&1, socket.assigns.current_scope, &2))
  end

  def handle_event("refresh_tools", %{"id" => id}, socket) do
    with_server(socket, id, fn socket, server ->
      case Mcp.refresh_server_tools(socket.assigns.current_scope, server) do
        {:ok, server} -> put_flash(socket, :info, "#{server.name}: #{length(server.tools)} tools.")
        {:error, reason} -> put_flash(socket, :error, "#{server.name}: #{describe(reason)}")
      end
    end)
  end

  def handle_event("toggle_enabled", %{"id" => id}, socket) do
    with_server(socket, id, fn socket, server ->
      {:ok, _server} = Mcp.update_server(socket.assigns.current_scope, server, %{enabled: !server.enabled})
      socket
    end)
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with_server(socket, id, fn socket, server ->
      {:ok, _server} = Mcp.delete_server(socket.assigns.current_scope, server)
      socket
    end)
  end

  # The navigation hook subscribes this view to pipeline events it does not use.
  def handle_info(_message, socket) do
    {:noreply, socket}
  end

  defp with_server(socket, id, fun) do
    socket =
      case Mcp.get_server(id: id) do
        {:ok, server} -> fun.(socket, server)
        {:error, :not_found} -> socket
      end

    {:noreply, assign(socket, :servers, Mcp.list_servers())}
  end

  defp discover(socket, scope, server) do
    socket =
      case Mcp.discover_server(scope, server) do
        {:ok, server} -> put_flash(socket, :info, "#{server.name}: #{status_label(server)}.")
        {:error, reason} -> put_flash(socket, :error, "#{server.name}: #{describe(reason)}")
      end

    assign(socket, :servers, Mcp.list_servers())
  end

  defp status_label(%{auth: :none}), do: "No auth"
  defp status_label(%{auth: :oauth, client_id: client_id}) when is_binary(client_id), do: "OAuth ready"
  defp status_label(_server), do: "Not discovered"

  defp status_class(%{auth: :oauth, client_id: nil}) do
    "inline-flex items-center rounded-md bg-amber-50 px-2 py-1 text-xs font-medium text-amber-700 ring-1 ring-inset ring-amber-600/20"
  end

  defp status_class(_ready) do
    "inline-flex items-center rounded-md bg-green-50 px-2 py-1 text-xs font-medium text-green-700 ring-1 ring-inset ring-green-600/20"
  end

  defp describe(:no_registration_endpoint), do: "the server does not support dynamic client registration."
  defp describe(:authorization_server_not_found), do: "no OAuth authorization server metadata found."
  defp describe(:not_connected), do: "connect your own account first (Connected Accounts)."
  defp describe(%Req.TransportError{reason: reason}), do: "could not reach the server (#{inspect(reason)})."
  defp describe(reason), do: inspect(reason)
end
