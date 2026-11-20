defmodule RailWeb.Components.CitedRules do
  @moduledoc """
  The learned rules one line of a plan cites by id, each with its kind, status and text, and a link to it.
  """
  use RailWeb, :html

  alias Rail.Learnings.Schemas.Learning

  attr :html, :string, required: true, doc: "the line's HTML, where each cited id is a code span"
  attr :rules, :map, required: true, doc: "the rules the plan cites, by id"

  def cited_rules(assigns) do
    assigns = assign(assigns, :cited, cited(assigns.html, assigns.rules))

    ~H"""
    <ul :if={@cited != []} data-qa="plan_cited_rules" class="mt-1 mb-2 space-y-1.5">
      <li
        :for={rule <- @cited}
        data-qa="plan_cited_rule"
        class="rounded-lg border border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-800/40 px-3 py-2"
      >
        <p class="flex flex-wrap items-center gap-x-3 gap-y-1">
          <.learning_kind kind={rule.kind} />
          <.learning_status learning={rule} flagged={rule.flagged} />
        </p>
        <p class="mt-1 text-[13px] font-medium text-slate-900 dark:text-slate-100 wrap-anywhere">
          {rule.rule}
        </p>
        <.link
          navigate={~p"/learnings/#{rule.id}"}
          class="mt-1 inline-flex items-center gap-1 text-xs font-semibold text-blue-600 dark:text-blue-400 hover:underline"
        >
          Open rule<.icon name="pi-arrow-up-right" class="size-3" />
        </.link>
      </li>
    </ul>
    """
  end

  # In the order the line cites them, each once, and only the ones the page loaded.
  defp cited(html, rules) do
    for [_code, id] <- Regex.scan(~r/<code>(lrn_[^<\s]+)<\/code>/, html || ""),
        rule = Map.get(rules, id),
        is_struct(rule, Learning),
        uniq: true,
        do: rule
  end
end
