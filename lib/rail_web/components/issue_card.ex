defmodule RailWeb.Components.IssueCard do
  @moduledoc """
  One issue as a single row of the issues list: priority, identifier, status and
  title on the left; where its work stands, its points and who owns it on the
  right.
  """
  use RailWeb, :html

  import RailWeb.CoreComponents, only: [icon: 1]

  alias Rail.Issues.Schemas.Issue
  alias RailWeb.Components.StageLabel

  attr :issue, :map, required: true
  attr :task, :map, default: nil
  attr :run, :any, default: nil

  def issue_card(assigns) do
    ~H"""
    <div
      id={"issue-card-#{@issue.id}"}
      data-qa={"issue-row issue-card-#{@issue.id}"}
      class="group flex items-center gap-3 h-11 px-4 cursor-pointer hover:bg-slate-50 dark:hover:bg-slate-800/60 transition-colors"
      phx-click="open_editor"
      phx-value-issue_id={@issue.id}
    >
      <span
        data-qa="issue-priority-badge"
        title={priority_label(@issue.priority)}
        class="flex items-center justify-center w-4 shrink-0"
      >
        <.priority_icon priority={@issue.priority} />
        <span class="sr-only">{priority_label(@issue.priority)}</span>
      </span>

      <span
        data-qa="issue-identifier"
        class="w-20 shrink-0 text-xs font-mono text-slate-500 dark:text-slate-400 truncate"
      >
        {@issue.identifier}
      </span>

      <span
        data-qa="issue-status-badge"
        title={status_label(@issue.state)}
        class="flex items-center justify-center w-4 shrink-0"
      >
        <.icon name={status_icon(@issue.state)} class={["h-4 w-4", status_color(@issue.state)]} />
        <span class="sr-only">{status_label(@issue.state)}</span>
      </span>

      <span
        data-qa="issue-title"
        title={@issue.title}
        class="flex-1 min-w-0 truncate text-sm font-medium text-slate-900 dark:text-slate-100"
      >
        {@issue.title}
      </span>

      <div class="flex items-center gap-2 shrink-0" onclick="event.stopPropagation()">
        <.link
          :if={@task != nil}
          navigate={~p"/tasks/#{@task.id}"}
          id={"task-link-#{@issue.id}"}
          data-qa={"task-link-#{@issue.id}"}
          class="inline-flex items-center gap-1.5 h-6 px-2 rounded-full border border-slate-200 dark:border-slate-700 text-xs text-slate-700 dark:text-slate-300 hover:bg-slate-100 dark:hover:bg-slate-700 transition-colors"
        >
          <.icon name="pi-git-branch" class="h-3.5 w-3.5 text-slate-500 dark:text-slate-400" />
          <span>{StageLabel.stage_label(@task, @run)}</span>
        </.link>

        <button
          :if={@task == nil and not Issue.finished_state?(@issue.state)}
          type="button"
          id={"start-product-run-#{@issue.id}"}
          data-qa={"start_product_run_#{@issue.id}"}
          phx-click="start_product_run"
          phx-value-issue_id={@issue.id}
          class="inline-flex items-center gap-1 h-6 px-2 rounded-full border border-slate-200 dark:border-slate-700 text-xs text-slate-700 dark:text-slate-300 opacity-60 group-hover:opacity-100 hover:bg-blue-600 hover:border-blue-600 hover:text-white transition cursor-pointer"
        >
          <.icon name="pi-play" class="h-3.5 w-3.5" />
          <span>Start</span>
        </button>

        <a
          :if={@issue.url not in [nil, ""]}
          href={@issue.url}
          target="_blank"
          rel="noopener noreferrer"
          data-qa="issue-external-link"
          title="Open issue in Linear"
          class="p-1 rounded text-slate-400 hover:text-slate-900 dark:hover:text-slate-100 transition-colors"
        >
          <.icon name="pi-arrow-square-out" class="h-4 w-4" />
        </a>

        <span
          :if={@issue.estimate}
          data-qa="issue-estimate"
          title={"#{@issue.estimate} points"}
          class="inline-flex items-center gap-1 h-6 px-2 rounded-full border border-slate-200 dark:border-slate-700 text-xs text-slate-600 dark:text-slate-300"
        >
          <.icon name="pi-triangle" class="h-3 w-3 text-slate-500 dark:text-slate-400" />
          {@issue.estimate}
        </span>

        <.assignee user={@issue.owner_user} />
      </div>
    </div>
    """
  end

  def priority_label(priority), do: Issue.priority_label(priority) || "Medium"

  def status_label(state), do: Issue.state_label(state) || "Triage"

  attr :user, :any, required: true

  # Who the issue belongs to, as their avatar or initials; an empty circle when
  # nobody does, so the column still lines up.
  defp assignee(%{user: %{avatar_url: url}} = assigns) when is_binary(url) and url != "" do
    ~H"""
    <img
      data-qa="issue-assignee"
      src={@user.avatar_url}
      alt={@user.name || @user.login}
      title={@user.name || @user.login}
      class="h-6 w-6 rounded-full shrink-0"
    />
    """
  end

  defp assignee(%{user: %{login: _login}} = assigns) do
    ~H"""
    <span
      data-qa="issue-assignee"
      title={@user.name || @user.login}
      class="flex items-center justify-center h-6 w-6 rounded-full shrink-0 bg-indigo-500 text-white text-[10px] font-semibold uppercase"
    >
      {initials(@user.name || @user.login)}
    </span>
    """
  end

  defp assignee(assigns) do
    ~H"""
    <span
      data-qa="issue-unassigned"
      title="Unassigned"
      class="h-6 w-6 rounded-full shrink-0 border border-dashed border-slate-300 dark:border-slate-600"
    />
    """
  end

  defp initials(name) do
    name
    |> String.split(~r/[\s._-]+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&String.first/1)
  end

  attr :priority, :atom, required: true

  # Drawn the way Linear draws it: an exclamation in a filled square for urgent,
  # otherwise three bars with one, two or three lit for low, medium and high.
  defp priority_icon(%{priority: :urgent} = assigns) do
    ~H"""
    <svg viewBox="0 0 16 16" class="h-4 w-4 text-orange-500" aria-hidden="true">
      <rect x="1" y="1" width="14" height="14" rx="3" fill="currentColor" />
      <rect x="7" y="4" width="2" height="5" rx="1" class="fill-white dark:fill-slate-900" />
      <rect x="7" y="10.5" width="2" height="2" rx="1" class="fill-white dark:fill-slate-900" />
    </svg>
    """
  end

  defp priority_icon(assigns) do
    assigns = assign(assigns, :lit, lit_bars(assigns.priority))

    ~H"""
    <svg viewBox="0 0 16 16" class="h-4 w-4 text-slate-500 dark:text-slate-400" aria-hidden="true">
      <rect
        :for={{x, height, bar} <- [{1.5, 5, 1}, {6.5, 8, 2}, {11.5, 11, 3}]}
        x={x}
        y={13.5 - height}
        width="3"
        height={height}
        rx="1"
        fill="currentColor"
        opacity={if bar <= @lit, do: "1", else: "0.3"}
      />
    </svg>
    """
  end

  defp lit_bars(:high), do: 3
  defp lit_bars(:low), do: 1
  defp lit_bars(_medium), do: 2

  defp status_icon(:triage), do: "pi-tray"
  defp status_icon(:backlog), do: "pi-circle-dashed"
  defp status_icon(:todo), do: "pi-circle"
  defp status_icon(:in_progress), do: "pi-circle-half-fill"
  defp status_icon(:in_review), do: "pi-circle-half-tilt-fill"
  defp status_icon(:done), do: "pi-check-circle-fill"
  defp status_icon(:canceled), do: "pi-x-circle-fill"
  defp status_icon(_other), do: "pi-circle-dashed"

  defp status_color(state) when state in [:in_progress, :in_review], do: "text-amber-500"
  defp status_color(:done), do: "text-indigo-500"
  defp status_color(_other), do: "text-slate-500 dark:text-slate-400"
end
