defmodule RailWeb.McpAuthorizeLive do
  @moduledoc false
  use RailWeb, :live_view

  alias Rail.Mcp
  alias Rail.Projects

  @loopback_hosts ["localhost", "127.0.0.1", "::1"]
  @kept_params ["client_id", "redirect_uri", "scope", "state", "resource", "code_challenge", "code_challenge_method"]

  def mount(params, _session, socket) do
    scope = socket.assigns.current_scope

    socket =
      socket
      |> assign(:page_title, "Connect to Rail")
      |> assign(:authorized, false)

    socket =
      with true <- is_binary(scope.user.github_id) || {:error, :github_required},
           {:ok, client} <- Mcp.validate_authorize_request(params),
           [_first | _rest] = projects <- Projects.list_projects(scope) do
        redirect_host = URI.parse(params["redirect_uri"]).host

        socket
        |> assign(:error, nil)
        |> assign(:client, client)
        |> assign(:projects, projects)
        |> assign(:redirect_host, redirect_host)
        |> assign(:show_loopback_note, redirect_host in @loopback_hosts)
        |> assign(:params, Map.take(params, @kept_params))
      else
        [] -> assign_error(socket, :access_denied)
        {:error, error} -> assign_error(socket, error)
      end

    {:ok, socket}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  def render(%{error: nil} = assigns) do
    ~H"""
    <main id="oauth-consent" class="h-screen overflow-y-auto bg-slate-50 dark:bg-slate-950">
      <div class="min-h-full flex flex-col items-center justify-center gap-8 px-6 py-10">
        <.rail_mark />
        <div
          id="mcp-authorize"
          class="w-full max-w-md rounded-xl bg-white dark:bg-slate-900 ring-1 ring-slate-200 dark:ring-slate-700 p-6"
        >
          <h1 class="text-xl font-bold text-slate-900 dark:text-slate-100 break-words">
            Connect <span id="mcp-client-name">{@client.name}</span>
          </h1>
          <p class="mt-1 text-sm text-slate-500 dark:text-slate-400 break-words">
            Signed in as <span class="text-slate-700 dark:text-slate-200">{@current_scope.user.login}</span>. {@client.name} will act as you, on tickets in these projects:
          </p>

          <ul id="mcp-projects" class="mt-3 space-y-1 text-sm text-slate-700 dark:text-slate-200">
            <li
              :for={project <- @projects}
              id={"mcp-project-#{project.id}"}
              class="flex items-center gap-2 min-w-0"
            >
              <.icon name="pi-folder" class="size-4 text-blue-500" />
              <span class="truncate">{project.name}</span>
              <span class="font-mono text-xs text-slate-400 dark:text-slate-500">{project.key}</span>
            </li>
          </ul>

          <p class="mt-3 text-sm text-slate-500 dark:text-slate-400">
            It can search, open, file and edit tickets and comment. It cannot start or approve tasks.
          </p>

          <p class="mt-5 text-[11px] font-bold uppercase tracking-wider text-slate-400 dark:text-slate-500">
            You will be sent to
          </p>
          <p
            id="mcp-redirect-host"
            class="mt-0.5 font-mono text-sm text-slate-700 dark:text-slate-200 break-all"
          >
            {@redirect_host}
          </p>
          <p
            :if={@show_loopback_note}
            id="mcp-loopback-note"
            class="mt-1 flex items-start gap-1.5 text-sm text-slate-600 dark:text-slate-300"
          >
            <.icon name="pi-desktop" class="size-4 mt-0.5 text-slate-400" />
            This app runs on your own computer. Only continue if you started this connection yourself.
          </p>

          <div class="mt-6 flex justify-end gap-2">
            <.button type="button" phx-click="cancel" id="mcp-cancel">Cancel</.button>
            <.button type="button" variant="primary" phx-click="authorize" id="mcp-allow">Allow</.button>
          </div>
        </div>
      </div>
    </main>
    """
  end

  def render(assigns) do
    ~H"""
    <main id="oauth-consent" class="h-screen overflow-y-auto bg-slate-50 dark:bg-slate-950">
      <div class="min-h-full flex flex-col items-center justify-center gap-8 px-6 py-10">
        <.rail_mark />
        <div
          id="mcp-authorize-error"
          class="w-full max-w-md rounded-xl bg-white dark:bg-slate-900 ring-1 ring-slate-200 dark:ring-slate-700 p-6 text-center"
        >
          <.icon name="pi-warning-circle" class="size-6 text-red-500 dark:text-red-400" />
          <h1 class="mt-2 text-lg font-bold text-slate-900 dark:text-slate-100">
            Authorization request invalid
          </h1>
          <p class="mt-1 text-sm text-slate-500 dark:text-slate-400">{@description}</p>
          <span class="mt-3 inline-block rounded px-1.5 py-0.5 font-mono text-[11px] text-slate-500 dark:text-slate-400 ring-1 ring-inset ring-slate-300 dark:ring-slate-600">
            error = {@error}
          </span>
        </div>
      </div>
    </main>
    """
  end

  # A second click while the first redirect is on its way issues no second code.
  def handle_event("authorize", _params, %{assigns: %{authorized: true}} = socket), do: {:noreply, socket}

  def handle_event("authorize", _params, socket) do
    socket =
      case Mcp.authorize(socket.assigns.current_scope, socket.assigns.params) do
        {:ok, %{redirect_url: url}} -> socket |> assign(:authorized, true) |> redirect(external: url)
        {:error, error} -> assign_error(socket, error)
      end

    {:noreply, socket}
  end

  def handle_event("cancel", _params, socket) do
    %{"redirect_uri" => redirect_uri} = params = socket.assigns.params
    uri = URI.parse(redirect_uri)

    query =
      (uri.query || "")
      |> URI.decode_query()
      |> Map.merge(%{"error" => "access_denied", "state" => params["state"]})
      |> Map.reject(fn {_key, value} -> is_nil(value) end)
      |> URI.encode_query()

    {:noreply, redirect(socket, external: URI.to_string(%{uri | query: query}))}
  end

  defp rail_mark(assigns) do
    ~H"""
    <div class="flex items-center justify-center size-14 shrink-0 rounded-2xl bg-blue-50 dark:bg-blue-950 text-blue-600 dark:text-blue-400 ring-1 ring-blue-100 dark:ring-blue-900">
      <svg viewBox="0 0 64 64" class="size-14" fill="none" aria-hidden="true" id="mcp-authorize-mark">
        <mask id="mcp-authorize-mark-rails" stroke-linejoin="round">
          <path d="M21 56V17H35a9.5 9.5 0 0 1 0 19H21M32 36 46 57" stroke="#fff" stroke-width="12" />
          <path d="M21 56V17H35a9.5 9.5 0 0 1 0 19H21M32 36 46 57" stroke="#000" stroke-width="4.5" />
        </mask>
        <rect width="64" height="52" fill="currentColor" mask="url(#mcp-authorize-mark-rails)" />
      </svg>
    </div>
    """
  end

  defp assign_error(socket, error) do
    socket
    |> assign(:error, error)
    |> assign(:description, describe(error))
  end

  defp describe(:invalid_client),
    do: "Rail does not know this client, or could not trust its metadata. Start again from Claude."

  defp describe(:invalid_request),
    do: "The return address does not match the client Claude registered. Start again from Claude."

  defp describe(:invalid_scope), do: "Claude may only ask for the mcp scope."
  defp describe(:invalid_target), do: "The connection names a server other than this Rail."
  defp describe(:unsupported_response_type), do: "Only response_type=code is supported."
  defp describe(:invalid_pkce), do: "The connection needs a PKCE challenge using S256."

  defp describe(:github_required),
    do: "Connect GitHub under Settings, Connected accounts before you connect Claude to Rail."

  defp describe(:access_denied),
    do:
      "You cannot open any project in Rail yet, so there is nothing to connect. An admin grants projects under Settings, Users."
end
