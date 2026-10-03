defmodule RailWeb.Components.LearningDetail do
  @moduledoc """
  One rule read in full: who activated it and when, the override flagging it,
  its figures, the findings it suppressed, and where it came from.
  """
  use RailWeb, :html

  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Schemas.LearningProposal
  alias Rail.Learnings.Schemas.Observation

  @shown 6

  attr :learning, Learning, required: true
  attr :stats, :map, required: true
  attr :show_all_suppressed, :boolean, default: false
  attr :error, :string, default: nil

  def learning_detail(assigns) do
    stats = assigns.stats

    rows =
      if assigns.show_all_suppressed, do: stats.suppressed_findings, else: Enum.take(stats.suppressed_findings, @shown)

    assigns =
      assigns
      |> assign(:flagged, stats.pending_override != nil)
      |> assign(:byline, calculate_byline(assigns.learning))
      |> assign(:rows, rows)
      |> assign(:more, length(stats.suppressed_findings) - length(rows))
      |> assign(:source_count, length(stats.sources) + if(stats.activated_by, do: 1, else: 0))

    ~H"""
    <section id="learning-detail" data-qa="learning-detail" class="flex-1 min-w-0 flex flex-col">
      <div class="shrink-0 flex items-start gap-4 px-7 py-4 border-b border-slate-200 dark:border-slate-700">
        <div class="min-w-0 flex-1">
          <div class="flex flex-wrap items-center gap-x-3 gap-y-1 text-xs">
            <.learning_kind kind={@learning.kind} />
            <.learning_status learning={@learning} flagged={@flagged} />
            <span class="text-slate-500 dark:text-slate-400">{@byline}</span>
          </div>
          <h2
            id="learning-rule"
            class="mt-2 text-lg font-bold text-slate-900 dark:text-slate-100 break-words"
          >
            {@learning.rule}
          </h2>
          <p class="mt-1 flex flex-wrap gap-x-3 text-xs text-slate-500 dark:text-slate-400">
            <span>{Learning.roles_label(@learning)}</span>
            <code
              :if={@learning.path_glob}
              class="font-mono text-[11.5px] text-slate-600 dark:text-slate-300 break-all"
            >
              {@learning.path_glob}
            </code>
            <span :if={@learning.pinned}>Pinned, so every run of these roles is given it</span>
          </p>
        </div>
        <div class="shrink-0 flex gap-2">
          <.button size="sm" id="edit-learning-button" phx-click="edit_learning">
            <.icon name="pi-pencil-simple" class="size-[1.1em]" />Edit
          </.button>
          <.button
            :if={@learning.status != :retired}
            size="sm"
            variant="danger"
            id="retire-learning-button"
            phx-click="retire_learning"
          >
            <.icon name="pi-archive" class="size-[1.1em]" />Retire
          </.button>
        </div>
      </div>

      <div class="flex-1 min-h-0 overflow-y-auto px-7 py-5 @container">
        <div class="max-w-[1100px] space-y-5">
          <p :if={@error} id="learnings-error" class="text-xs text-red-600 dark:text-red-500">
            {@error}
          </p>

          <div
            :if={@flagged}
            id="learning-override-banner"
            class="flex items-center gap-3 rounded-lg border border-amber-400/50 bg-amber-50 dark:bg-amber-950/20 px-4 py-2.5"
          >
            <.icon name="pi-flag-fill" class="size-4 text-amber-600 dark:text-amber-400" />
            <p class="flex-1 min-w-0 text-[13px] text-amber-900 dark:text-amber-100">
              <.override_line override={@stats.pending_override} />
            </p>
            <.button
              size="sm"
              id="keep-rule-button"
              phx-click="keep_rule"
              phx-value-id={@stats.pending_override.proposal.id}
            >
              <.icon name="pi-check-bold" class="size-[1.1em]" />Keep rule
            </.button>
          </div>

          <p
            :if={@learning.why}
            id="learning-why"
            phx-no-format
            class="text-[13.5px] leading-relaxed text-slate-700 dark:text-slate-300 whitespace-pre-wrap break-words"
          >{@learning.why}</p>

          <div
            id="learning-figures"
            class="grid grid-cols-4 rounded-xl border border-slate-200 dark:border-slate-700 divide-x divide-slate-200 dark:divide-slate-700"
          >
            <.figure value={@stats.runs} label="runs given it" />
            <.figure value={@stats.broken} label="broken anyway" />
            <.figure value={@stats.suppressed} label="findings suppressed" />
            <.figure
              value={@stats.overrides}
              label={if @stats.overrides == 1, do: "override", else: "overrides"}
              alert={@flagged}
            />
          </div>

          <div class="grid gap-6 grid-cols-1 @min-[960px]:grid-cols-[minmax(0,1.6fr)_minmax(0,1fr)]">
            <div :if={@stats.suppressed_findings != []} id="learning-suppressed" class="min-w-0">
              <p class="mb-2 text-xs font-semibold uppercase tracking-wider text-slate-500 dark:text-slate-400">
                Suppressed findings · {length(@stats.suppressed_findings)} across {calculate_tasks(
                  @stats.suppressed_tasks
                )}
              </p>
              <div class="rounded-xl border border-slate-200 dark:border-slate-700 overflow-hidden">
                <table class="w-full table-fixed">
                  <colgroup>
                    <col class="w-20" />
                    <col />
                    <col class="w-32" />
                    <col class="w-16" />
                  </colgroup>
                  <tbody>
                    <tr
                      :for={%{finding: finding, overridden?: overridden?} <- @rows}
                      id={"suppressed-#{finding.id}"}
                      class="border-t first:border-t-0 border-slate-200 dark:border-slate-700/70"
                    >
                      <td class="px-3 py-2 font-mono text-xs text-slate-500 dark:text-slate-400 whitespace-nowrap">
                        {finding.task.issue.identifier}
                      </td>
                      <td class="px-3 py-2 max-w-0 w-full">
                        <.link
                          navigate={~p"/tasks/#{finding.task_id}"}
                          class="block truncate text-[13px] text-slate-800 dark:text-slate-200 hover:underline"
                        >
                          {finding.title}
                        </.link>
                        <span
                          :if={finding.file}
                          class="block truncate font-mono text-[10.5px] text-slate-500 dark:text-slate-400"
                        >
                          {finding.file}{if finding.line, do: ":#{finding.line}"}
                        </span>
                      </td>
                      <td class="px-3 py-2 whitespace-nowrap text-xs">
                        <span
                          :if={overridden?}
                          class="inline-flex items-center gap-1 font-semibold text-amber-600 dark:text-amber-400"
                        >
                          <.icon name="pi-flag-fill" class="size-3" />Fixed anyway
                        </span>
                        <span :if={not overridden?} class="text-slate-500 dark:text-slate-400">Suppressed</span>
                      </td>
                      <td class="px-3 py-2 text-right font-mono text-[11px] text-slate-500 dark:text-slate-400 whitespace-nowrap">
                        {calculate_date(finding.inserted_at)}
                      </td>
                    </tr>
                  </tbody>
                </table>
                <button
                  :if={@more > 0}
                  type="button"
                  id="suppressed-more"
                  phx-click="show_all_suppressed"
                  class="block w-full text-left px-3 py-2 border-t border-slate-200 dark:border-slate-700 text-xs font-semibold text-blue-600 dark:text-blue-400 hover:underline cursor-pointer"
                >
                  {@more} more
                </button>
              </div>
            </div>

            <div id="learning-sources" class="min-w-0">
              <p class="mb-2 text-xs font-semibold uppercase tracking-wider text-slate-500 dark:text-slate-400">
                Sources · {@source_count}
              </p>
              <p :if={@source_count == 0} class="text-xs text-slate-500 dark:text-slate-400">
                Written by a person on this page.
              </p>
              <ul class="divide-y divide-slate-200 dark:divide-slate-700/70">
                <li :for={observation <- @stats.sources} class="flex items-start gap-2.5 py-2">
                  <.icon
                    name={source_icon(observation.source_kind)}
                    class="mt-0.5 size-4 text-slate-400"
                  />
                  <span class="min-w-0 flex-1">
                    <span class="block text-[11px] text-slate-500 dark:text-slate-400">
                      {Observation.source_label(observation.source_kind)} · {Observation.actor_label(
                        observation
                      )}
                    </span>
                    <.source_link observation={observation} />
                  </span>
                </li>
                <li :if={@stats.activated_by} class="flex items-start gap-2.5 py-2">
                  <.icon name="pi-play-circle" class="mt-0.5 size-4 text-slate-400" />
                  <span class="min-w-0 flex-1">
                    <span class="block text-[11px] text-slate-500 dark:text-slate-400">
                      {activation_label(@stats.activated_by)}
                    </span>
                    <span class="block truncate text-[13px] text-slate-700 dark:text-slate-300">
                      {calculate_date(@stats.activated_by.decided_at)} · {@stats.activated_by.summary ||
                        @stats.activated_by.title || "activated"}
                    </span>
                  </span>
                </li>
              </ul>
            </div>
          </div>
        </div>
      </div>
    </section>
    """
  end

  attr :value, :integer, required: true
  attr :label, :string, required: true
  attr :alert, :boolean, default: false

  defp figure(assigns) do
    ~H"""
    <div class="px-5 py-3 min-w-0">
      <p class={[
        "text-2xl font-semibold tabular-nums",
        @alert && @value > 0 && "text-amber-600 dark:text-amber-400",
        not (@alert && @value > 0) && "text-slate-900 dark:text-slate-100"
      ]}>
        {@value}
      </p>
      <p class="text-xs text-slate-500 dark:text-slate-400">{@label}</p>
    </div>
    """
  end

  attr :override, :map, required: true

  defp override_line(%{override: %{observation: %Observation{} = observation, finding: %{} = finding}} = assigns) do
    assigns = assigns |> assign(:observation, observation) |> assign(:finding, finding)

    ~H"""
    Flagged: {Observation.actor_label(@observation)} decided Fix on <.link
      navigate={~p"/tasks/#{@finding.task_id}"}
      class="underline"
    >{@finding.title}</.link>, which this rule suppressed on <span class="font-mono">{@finding.task.issue.identifier}</span>.
    """
  end

  defp override_line(assigns) do
    ~H"""
    Flagged: a person decided Fix on a finding this rule suppressed.
    """
  end

  attr :observation, Observation, required: true

  defp source_link(%{observation: %Observation{task: %{issue: %{identifier: identifier}}}} = assigns) do
    assigns = assign(assigns, :identifier, identifier)

    ~H"""
    <.link
      navigate={~p"/tasks/#{@observation.task_id}"}
      class="block truncate text-[13px] text-blue-600 dark:text-blue-400 hover:underline"
    >
      {@identifier} · {@observation.text}
    </.link>
    """
  end

  defp source_link(%{observation: %Observation{source_url: url}} = assigns) when is_binary(url) do
    ~H"""
    <.link
      href={@observation.source_url}
      target="_blank"
      rel="noopener"
      class="block truncate text-[13px] text-blue-600 dark:text-blue-400 hover:underline"
    >
      {@observation.text}
    </.link>
    """
  end

  defp source_link(assigns) do
    ~H"""
    <span class="block truncate text-[13px] text-slate-700 dark:text-slate-300">{@observation.text}</span>
    """
  end

  defp calculate_byline(%Learning{status: :retired, retired_at: at}), do: "retired #{calculate_date(at)}"
  defp calculate_byline(%Learning{status: :provisional, inserted_at: at}), do: "provisional since #{calculate_date(at)}"
  defp calculate_byline(%Learning{status: :proposed, inserted_at: at}), do: "drafted #{calculate_date(at)}"
  defp calculate_byline(%Learning{auto: true, activated_at: at}), do: "by the curator, #{calculate_date(at)}"

  defp calculate_byline(%Learning{approved_by: %{name: name}, activated_at: at}) when is_binary(name),
    do: "by #{name}, #{calculate_date(at)}"

  defp calculate_byline(%Learning{activated_at: at}), do: "since #{calculate_date(at)}"

  defp activation_label(%LearningProposal{decided_by: %{name: name}}) when is_binary(name), do: "Approved · #{name}"
  defp activation_label(%LearningProposal{}), do: "Curator run · Curator"

  defp source_icon(kind) when kind in [:pr_review_comment, :pr_review], do: "pi-git-pull-request"
  defp source_icon(:extraction), do: "pi-play-circle"
  defp source_icon(_comment_or_finding), do: "pi-chat-centered-text"

  defp calculate_tasks(1), do: "1 task"
  defp calculate_tasks(count), do: "#{count} tasks"

  defp calculate_date(%DateTime{} = at), do: Calendar.strftime(at, "%b %-d")
end
