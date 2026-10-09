defmodule RailWeb.Components.CommitPicker do
  @moduledoc """
  The Diff toolbar's first control, carrying which of the branch the pane shows: the whole branch with its
  range, commit count, files and stat, the uncommitted work while there is any, then each commit newest
  first, labeled by what made it, with its sha, any conflicts a merge resolved, subject, time and stat.
  """
  use RailWeb, :html

  attr :view, :any, required: true, doc: "`:branch`, `:uncommitted` or `{:commit, sha}`"
  attr :history, :map, required: true, doc: "the branch as `Rail.Git.load_branch_history/1` reads it"
  attr :dirty?, :boolean, default: false, doc: "the worktree has uncommitted work"
  attr :target, :any, required: true

  def commit_picker(assigns) do
    assigns =
      assigns
      |> assign(:picked, picked(assigns.view, assigns.history.commits))
      |> assign(:close, close())

    ~H"""
    <div class="relative shrink-0 min-w-0" phx-click-away={@close}>
      <button
        type="button"
        id="diff-commit-picker"
        data-qa="diff_commit_picker"
        aria-haspopup="listbox"
        aria-expanded="false"
        aria-controls="diff-commit-listbox"
        phx-keydown={@close}
        phx-key="Escape"
        phx-click={
          JS.toggle(to: "#diff-commit-listbox")
          |> JS.toggle_attribute({"aria-expanded", "true", "false"})
          |> JS.focus_first(to: "#diff-commit-listbox")
        }
        class="shrink-0 inline-flex items-center gap-2 max-w-[16rem] h-8 px-2.5 rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-800 text-xs text-slate-900 dark:text-slate-100 cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
      >
        <.icon name="pi-git-commit" class="size-[15px] shrink-0 text-slate-400" />
        <span :if={@view == :branch} class="shrink-0 font-semibold">Whole branch</span>
        <span
          :if={@view == :branch}
          class="hidden @3xl:inline truncate text-slate-500 dark:text-slate-400"
        >
          {plural(length(@history.commits), "commit")}
        </span>
        <span :if={@view == :uncommitted} class="truncate font-semibold">Uncommitted</span>
        <span :if={@picked} class="shrink-0 font-mono text-slate-500 dark:text-slate-400">
          {@picked.short_sha}
        </span>
        <span :if={@picked} class="truncate font-semibold">{@picked.label}</span>
        <.icon name="pi-caret-down" class="size-3 shrink-0 text-slate-400" />
      </button>

      <div
        id="diff-commit-listbox"
        role="listbox"
        aria-label="Commit"
        data-qa="diff_commit_listbox"
        class="hidden absolute left-0 top-9 z-30 w-[22rem] max-w-[calc(100vw-2rem)] max-h-[min(28rem,70vh)] overflow-y-auto rounded-xl border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-800 p-1.5 shadow-xl"
      >
        <.option
          id="diff-commit-option-branch"
          value="branch"
          selected={@view == :branch}
          target={@target}
          close={@close}
          icon="pi-git-branch"
          title="Whole branch"
          detail={whole(@history)}
          additions={@history.additions}
          deletions={@history.deletions}
        />
        <.option
          :if={@dirty? or @view == :uncommitted}
          id="diff-commit-option-uncommitted"
          value="uncommitted"
          selected={@view == :uncommitted}
          target={@target}
          close={@close}
          icon="pi-pencil-simple-line"
          title="Uncommitted"
          detail="What is not committed yet"
        />

        <p
          :if={@history.commits != []}
          class="px-2.5 pt-2 pb-1 text-[10.5px] font-extrabold uppercase tracking-[0.14em] text-slate-400 dark:text-slate-500"
        >
          Commits, newest first
        </p>
        <.option
          :for={commit <- @history.commits}
          id={"diff-commit-option-#{commit.short_sha}"}
          value={commit.sha}
          selected={@view == {:commit, commit.sha}}
          target={@target}
          close={@close}
          icon="pi-git-commit"
          title={commit.label}
          sha={commit.short_sha}
          conflicts={commit.conflicts}
          detail={subject(commit, @history.base)}
          at={commit.at}
          additions={commit.additions}
          deletions={commit.deletions}
        />
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :value, :string, required: true
  attr :selected, :boolean, required: true
  attr :target, :any, required: true
  attr :close, JS, required: true
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :detail, :string, required: true
  attr :sha, :string, default: nil
  attr :conflicts, :integer, default: 0
  attr :at, DateTime, default: nil
  attr :additions, :integer, default: nil
  attr :deletions, :integer, default: nil

  defp option(assigns) do
    ~H"""
    <button
      type="button"
      role="option"
      id={@id}
      data-qa="diff_commit_option"
      aria-selected={to_string(@selected)}
      phx-click={@close |> JS.push("pick_commit", value: %{commit: @value}, target: @target)}
      phx-keydown={@close |> JS.focus(to: "#diff-commit-picker")}
      phx-key="Escape"
      class={[
        "w-full flex items-start gap-2.5 px-2.5 py-2 rounded-lg text-left cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500",
        @selected && "bg-blue-50 dark:bg-blue-950/40",
        not @selected && "hover:bg-slate-100 dark:hover:bg-slate-700/60"
      ]}
    >
      <.icon name={@icon} class="mt-0.5 size-[15px] shrink-0 text-slate-400" />
      <span class="min-w-0 flex-1">
        <span class="flex items-center gap-2 min-w-0">
          <span class="whitespace-nowrap text-[13px] font-semibold text-slate-900 dark:text-slate-100">
            {@title}
          </span>
          <span :if={@sha} class="font-mono text-[11px] text-slate-500 dark:text-slate-400">{@sha}</span>
          <span
            :if={@conflicts > 0}
            data-qa="diff_commit_conflicts"
            class="shrink-0 whitespace-nowrap rounded px-1.5 py-px text-[10px] font-semibold bg-slate-100 dark:bg-slate-700 text-slate-600 dark:text-slate-300"
          >
            {plural(@conflicts, "conflict")}
          </span>
        </span>
        <span class="block truncate text-[11px] text-slate-500 dark:text-slate-400">
          {@detail}<span :if={@at}> · <.local_time id={"#{@id}-at"} at={@at} /></span>
        </span>
      </span>
      <.diff_stat
        :if={@additions}
        additions={@additions}
        deletions={@deletions}
        font_size={11}
        class="shrink-0"
      />
    </button>
    """
  end

  # The listbox closes however it is left: a pick, a click elsewhere, or Escape, which LiveView hears only on
  # the element that has the focus, so the button and each option listen for it.
  defp close do
    [to: "#diff-commit-listbox"]
    |> JS.hide()
    |> JS.set_attribute({"aria-expanded", "false"}, to: "#diff-commit-picker")
  end

  defp picked({:commit, sha}, commits), do: Enum.find(commits, &(&1.sha == sha))
  defp picked(_view, _commits), do: nil

  defp whole(%{base: base, head: head, files: files}) when is_binary(head),
    do: "#{base}...#{head} · #{plural(files, "file")}"

  defp whole(%{base: base}), do: "Everything since #{base}"

  defp subject(%{merge?: true, merged: merged}, base), do: "Merge origin/#{base} (#{merged})"
  defp subject(%{subject: subject}, _base), do: subject

  defp plural(1, word), do: "1 #{word}"
  defp plural(count, word), do: "#{count} #{word}s"
end
