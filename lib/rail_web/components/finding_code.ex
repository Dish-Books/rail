defmodule RailWeb.Components.FindingCode do
  @moduledoc """
  The code one place of a finding names, as `Rail.Git.load_diff_hunks/3` reads it: a note when the branch
  does not change those lines, the lines with the named ones bracketed, and what the excerpt leaves out.
  """
  use RailWeb, :html

  attr :excerpt, :map, required: true
  attr :head, :string, default: nil, doc: "the commit the branch is on, which unchanged lines read as"

  # Always wrapped, whatever the reader picked in the Diff item, so a card never scrolls sideways.
  def finding_code(assigns) do
    assigns = assign(assigns, :footer, footer(assigns.excerpt))

    ~H"""
    <div data-qa="finding_code" data-diff-wrap>
      <p
        :if={not @excerpt.changed?}
        data-qa="finding_code_unchanged"
        class="px-3.5 py-1.5 border-b border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900 text-[11.5px] text-slate-500 dark:text-slate-400"
      >
        The branch does not change these lines. They read as the file does{if @head,
          do: " on #{String.slice(@head, 0, 7)}"}.
      </p>
      <.diff_hunk rows={@excerpt.rows} />
      <p
        :if={@footer}
        data-qa="finding_code_footer"
        class="px-3.5 py-2 border-t border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-800/40 text-[11.5px] text-slate-500 dark:text-slate-400"
      >
        {@footer}
      </p>
    </div>
    """
  end

  defp footer(%{changed?: false, other_changes: 0}), do: nil
  defp footer(%{changed?: false, other_changes: 1}), do: "1 change elsewhere in this file, none on these lines."

  defp footer(%{changed?: false, other_changes: others}),
    do: "#{others} changes elsewhere in this file, none on these lines."

  defp footer(%{hidden_lines: hidden, other_changes: others}) do
    [{hidden, "more changed line", "more changed lines"}, {others, "other change", "other changes"}]
    |> Enum.reject(fn {count, _one, _many} -> count == 0 end)
    |> Enum.map(fn
      {1, one, _many} -> "1 #{one}"
      {count, _one, many} -> "#{count} #{many}"
    end)
    |> case do
      [] -> nil
      parts -> "#{Enum.join(parts, " and ")} in this file."
    end
  end
end
