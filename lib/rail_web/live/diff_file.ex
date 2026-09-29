defmodule RailWeb.Live.DiffFile do
  @moduledoc """
  One file of the diff pane, a component of its own so that marking it reviewed
  or re-reading it patches this file and not every line of the pane.
  """
  use RailWeb, :live_component

  import RailWeb.Utils.DiffFileName
  import RailWeb.Utils.DiffStatusStyle

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :file_name, diff_file_name(assigns.file))

    ~H"""
    <div
      id={"diff-file-#{slug(@id)}"}
      data-qa="diff_file_section"
      data-path={@file.path}
      phx-hook="DiffSection"
      class="first:mt-3 rounded-xl border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900"
    >
      <div
        id={"diff-header-#{slug(@id)}"}
        data-qa="diff_file_header"
        class={[
          "sticky -top-px z-10 h-11 px-3 flex items-center gap-2 rounded-t-xl data-stuck:rounded-t-none",
          "bg-slate-100 dark:bg-slate-800 border-b border-slate-200 dark:border-slate-700",
          @collapsed? && "rounded-b-xl"
        ]}
      >
        <button
          type="button"
          phx-click="toggle_collapsed"
          phx-target={@target}
          phx-value-path={@file.path}
          data-qa="diff_collapse_toggle"
          aria-label={"Fold #{@file.display_path}"}
          aria-expanded={to_string(not @collapsed?)}
          class="size-5 shrink-0 grid place-items-center rounded text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100 cursor-pointer"
        >
          <.icon name={if @collapsed?, do: "pi-caret-right", else: "pi-caret-down"} class="size-3.5" />
        </button>

        <span class="min-w-0 flex font-mono text-xs">
          <span class="truncate text-slate-500 dark:text-slate-400">{@file_name.dir}</span>
          <span class="shrink-0 font-bold text-slate-900 dark:text-slate-100">{@file_name.name}</span>
        </span>

        <.status_badge status={@file.status} />

        <span class="ml-auto shrink-0 flex items-center gap-3">
          <.diff_stat additions={@file.additions} deletions={@file.deletions} font_size={11} />

          <button
            type="button"
            phx-click="toggle_viewed"
            phx-target={@target}
            phx-value-path={@file.path}
            phx-value-digest={@file.digest}
            aria-pressed={to_string(@viewed?)}
            data-qa="diff-viewed-checkbox"
            class={[
              "inline-flex items-center gap-1.5 pl-1.5 pr-2.5 py-1 rounded-lg border text-xs font-semibold cursor-pointer",
              @viewed? &&
                "border-emerald-500/40 bg-emerald-500/10 text-emerald-700 dark:text-emerald-400",
              not @viewed? &&
                "border-slate-200 dark:border-slate-700 text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100"
            ]}
          >
            <span class={[
              "size-4 grid place-items-center rounded border",
              @viewed? && "border-emerald-500 bg-emerald-500 text-white",
              not @viewed? && "border-slate-300 dark:border-slate-600"
            ]}>
              <.icon :if={@viewed?} name="pi-check" class="size-3" />
            </span>
            Reviewed
          </button>
        </span>
      </div>

      <div
        :if={not @collapsed?}
        style={"content-visibility: auto; contain-intrinsic-size: auto #{intrinsic_height(@rows)}px;"}
        class="overflow-x-auto rounded-b-xl"
      >
        <div class="min-w-max">
          <.diff_row
            :for={row <- @rows}
            row={row}
            expanded={expanded(@expanded_gaps, row)}
            target={@target}
          />
        </div>
      </div>
    </div>
    """
  end

  attr :status, :atom, required: true

  # Modified is what a file in a diff is unless it says otherwise, and needs no
  # label of its own.
  defp status_badge(assigns) do
    assigns = assign(assigns, :style, diff_status_style(assigns.status))

    ~H"""
    <span
      :if={@style.label}
      data-qa="diff_status_badge"
      class={[
        "shrink-0 px-1.5 py-0.5 rounded text-[10px] font-bold uppercase tracking-wider",
        @style.color,
        @style.tint
      ]}
    >
      {@style.label}
    </span>
    """
  end

  defp expanded(expanded_gaps, %{kind: :gap, key: key}), do: Map.get(expanded_gaps, key)
  defp expanded(_expanded_gaps, _row), do: nil

  # A row each, at the height rows are drawn at. Only a guess for a file that has
  # not been rendered yet, which is all the browser wants.
  defp intrinsic_height(rows), do: length(rows) * 22

  defp slug(id), do: id |> String.replace(~r/[^a-zA-Z0-9_-]/, "-") |> String.trim("-")
end
