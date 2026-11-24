defmodule RailWeb.Components.DescriptionEditor do
  @moduledoc """
  An issue's description, edited in place by the `IssueDescription` hook and saved as the person goes. Files dropped or
  pasted into it go up through its `IssueUpload`.
  """
  use RailWeb, :live_component

  alias Rail.Issues
  alias RailWeb.Components.IssueUpload

  def update(assigns, socket) do
    socket =
      socket
      |> assign(:id, assigns.id)
      |> assign(:issue, assigns.issue)
      |> assign(:current_scope, assigns.current_scope)
      |> assign(:overlay_id, assigns.overlay_id)

    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <div id={@id} class="space-y-3">
      <%!-- LiveView leaves the editor alone; the saved text rides on data-saved, which the hook takes when it can. --%>
      <div
        id={"issue-description-#{@issue.id}"}
        data-qa="issue-description"
        phx-hook="IssueDescription"
        phx-update="ignore"
        data-issue-id={@issue.id}
        data-saved={@issue.description || ""}
        data-notice={"#{@id}-notice"}
        data-retry={"#{@id}-retry"}
        data-upload-form={"#{@id}-upload"}
        data-overlay={@overlay_id}
        class="min-h-6 break-words"
      >
        <.markdown
          :if={@issue.description not in [nil, ""]}
          content={@issue.description}
          class="text-slate-700 dark:text-slate-300"
        />
        <p :if={@issue.description in [nil, ""]} class="text-sm text-slate-400 dark:text-slate-500">
          Add description...
        </p>
      </div>

      <.live_component
        module={IssueUpload}
        id={"#{@id}-upload"}
        issue={@issue}
        current_scope={@current_scope}
      />

      <%!-- The hook shows this while Rail cannot take a save, so it is rendered hidden and never by the server. --%>
      <div
        id={"#{@id}-notice"}
        role="alert"
        class="hidden items-start gap-3 rounded-xl border border-red-300 dark:border-red-500/60 bg-red-50 dark:bg-red-950/50 px-4 py-3"
      >
        <.icon
          name="pi-warning-circle-fill"
          class="h-5 w-5 shrink-0 mt-0.5 text-red-600 dark:text-red-400"
        />
        <div class="flex-1 min-w-0 space-y-0.5">
          <p class="text-sm font-semibold text-red-800 dark:text-red-200">
            Couldn't save the description
          </p>
          <p class="text-sm text-red-700 dark:text-red-200/80">
            Your changes are kept in this browser and save as soon as Rail can take them.
          </p>
        </div>
        <button
          type="button"
          id={"#{@id}-retry"}
          class="shrink-0 inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-semibold border border-red-400/60 text-red-800 dark:text-red-100 hover:bg-red-100 dark:hover:bg-red-900/60 cursor-pointer focus-visible:outline-2 focus-visible:outline-red-400"
        >
          <.icon name="pi-arrow-clockwise" class="h-3.5 w-3.5" />Retry now
        </button>
      </div>
    </div>
    """
  end

  def handle_event("save_description", %{"description" => description}, socket) when is_binary(description) do
    %{issue: issue, current_scope: scope} = socket.assigns

    case Issues.edit_issue(scope, issue, %{"description" => description}) do
      {:ok, _issue} -> {:reply, %{ok: true}, socket}
      {:error, _reason} -> {:reply, %{ok: false}, socket}
    end
  end

  def handle_event("save_description", _malformed, socket), do: {:reply, %{ok: false}, socket}
end
