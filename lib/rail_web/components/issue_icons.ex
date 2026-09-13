defmodule RailWeb.Components.IssueIcons do
  @moduledoc """
  The small marks an issue is read by, drawn the way Linear draws them: its
  priority, its status and who owns it. The issues list and the issue page share
  them.
  """
  use RailWeb, :html

  attr :priority, :atom, required: true

  # An exclamation in a filled square for urgent, otherwise three bars with one,
  # two or three lit for low, medium and high.
  def priority_icon(%{priority: :urgent} = assigns) do
    ~H"""
    <svg viewBox="0 0 16 16" class="h-4 w-4 text-orange-500" aria-hidden="true">
      <rect x="1" y="1" width="14" height="14" rx="3" fill="currentColor" />
      <rect x="7" y="4" width="2" height="5" rx="1" class="fill-white dark:fill-slate-900" />
      <rect x="7" y="10.5" width="2" height="2" rx="1" class="fill-white dark:fill-slate-900" />
    </svg>
    """
  end

  def priority_icon(assigns) do
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

  attr :state, :atom, required: true

  def status_icon(assigns) do
    ~H"""
    <.icon name={status_icon_name(@state)} class={["h-4 w-4", status_color(@state)]} />
    """
  end

  attr :user, :any, required: true

  # Who the issue belongs to, as their avatar or initials; an empty circle when
  # nobody does, so a column of them still lines up.
  def assignee(%{user: %{avatar_url: url}} = assigns) when is_binary(url) and url != "" do
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

  def assignee(%{user: %{login: _login}} = assigns) do
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

  def assignee(assigns) do
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

  defp lit_bars(:high), do: 3
  defp lit_bars(:low), do: 1
  defp lit_bars(_medium), do: 2

  defp status_icon_name(:triage), do: "pi-tray"
  defp status_icon_name(:backlog), do: "pi-circle-dashed"
  defp status_icon_name(:todo), do: "pi-circle"
  defp status_icon_name(:in_progress), do: "pi-circle-half-fill"
  defp status_icon_name(:in_review), do: "pi-circle-half-tilt-fill"
  defp status_icon_name(:done), do: "pi-check-circle-fill"
  defp status_icon_name(:canceled), do: "pi-x-circle-fill"
  defp status_icon_name(_other), do: "pi-circle-dashed"

  defp status_color(state) when state in [:in_progress, :in_review], do: "text-amber-500"
  defp status_color(:done), do: "text-indigo-500"
  defp status_color(_other), do: "text-slate-500 dark:text-slate-400"
end
