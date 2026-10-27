defmodule Rail.Learnings.Actions.RecordCorrections do
  @moduledoc """
  Turns the corrections a person sent into provisional rules the same day, each source once, so a resend adds nothing.
  An answer taken from the rule Rail suggested, or a Fix on a finding raised from a rule, joins that rule instead.
  """

  import Ecto.Query
  import Rail.Learnings.Utils.BroadcastLearningsChanged
  import Rail.Learnings.Utils.EnqueueEmbedding
  import Rail.Learnings.Utils.InsertObservations

  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Schemas.Observation
  alias Rail.Pipeline.Schemas.DiffComment
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.FindingComment
  alias Rail.Pipeline.Schemas.PlanComment
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.ScreenComment
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Records `records`, diff, plan, screen and finding comments, Fix findings and answered questions
  of `task`. Returns `{:ok, learnings}`, the provisional rules it added.
  """
  def record_corrections(%Task{id: task_id, project_id: project_id}, records) when is_list(records) do
    suggested = suggested_answers(records)

    {:ok, {observations, learnings}} =
      Repo.transaction(fn ->
        observations =
          insert_observations(project_id, Enum.map(records, &Map.put(observation(&1, suggested), :task_id, task_id)))

        sources = Map.new(records, &{source_id(&1), &1})

        learnings =
          for %Observation{learning_id: nil} = observation <- observations do
            learning = insert_learning(project_id, Map.fetch!(sources, observation.source_id), observation)
            observation |> Ecto.Changeset.change(learning_id: learning.id) |> Repo.update!()
            learning
          end

        enqueue_embedding(learnings)
        {observations, learnings}
      end)

    if observations != [], do: broadcast_learnings_changed(project_id)
    {:ok, learnings}
  end

  defp source_id(%{id: id}), do: id

  # The answer each suggestion offered, as the gate works it out, so one taken as offered is told apart from one rewritten.
  defp suggested_answers(records) do
    ids = for %Question{suggested_learning_id: id} <- records, is_binary(id), do: id

    from(l in Learning,
      where: l.id in ^ids,
      preload: [observations: ^from(o in Observation, where: o.source_kind == :answer)]
    )
    |> Repo.all()
    |> Map.new(&{&1.id, Learning.calculate_answer(&1, &1.observations)})
  end

  defp observation(%DiffComment{} = comment, _suggested) do
    %{
      source_kind: :diff_comment,
      source_id: comment.id,
      actor_id: comment.user_id,
      text: comment.body,
      excerpt: block(comment)
    }
  end

  defp observation(%ScreenComment{} = comment, _suggested) do
    %{
      source_kind: :screen_comment,
      source_id: comment.id,
      actor_id: comment.user_id,
      text: comment.body,
      excerpt: screen_line(comment)
    }
  end

  defp observation(%FindingComment{} = comment, _suggested) do
    %{
      source_kind: :finding_comment,
      source_id: comment.id,
      actor_id: comment.user_id,
      text: comment.body,
      excerpt: comment.quote
    }
  end

  # A design comment keeps its element whole for the Learnings page to draw; its rule carries only the start of it.
  defp observation(%PlanComment{target: :design, capture: capture} = comment, _suggested) do
    %{
      source_kind: :design_comment,
      source_id: comment.id,
      actor_id: comment.user_id,
      text: comment.body,
      excerpt: element_block(comment),
      capture: %{"html" => capture.html, "width" => capture.width, "height" => capture.height}
    }
  end

  defp observation(%PlanComment{target: target} = comment, _suggested) do
    %{
      source_kind: if(target == :ticket, do: :ticket_comment, else: :plan_comment),
      source_id: comment.id,
      actor_id: comment.user_id,
      text: comment.body,
      excerpt: comment.element_text
    }
  end

  # A code finding teaches what review reads for, a screen finding what QA drives for.
  defp observation(%Finding{} = finding, _suggested) do
    %{
      source_kind: if(finding.kind == :screen, do: :qa_finding, else: :review_finding),
      source_id: finding.id,
      actor_id: finding.decided_by_id,
      text: finding.title,
      excerpt: finding.problem,
      learning_id: finding.rule_id
    }
  end

  defp observation(%Question{} = question, suggested) do
    taken = question.suggested_learning_id && Map.get(suggested, question.suggested_learning_id) == question.answer

    %{
      source_kind: :answer,
      source_id: question.id,
      actor_id: question.answered_by_id,
      text: question.prompt,
      excerpt: question.answer,
      learning_id: if(taken, do: question.suggested_learning_id)
    }
  end

  defp insert_learning(project_id, source, %Observation{} = observation) do
    %Learning{project_id: project_id, status: :provisional}
    |> Learning.changeset(rule(source, observation))
    |> Repo.insert!()
  end

  defp rule(%DiffComment{} = comment, _observation) do
    %{
      kind: :convention,
      roles: [:engineer, :review],
      rule: clip(comment.body),
      why: "From a diff comment on #{comment.path}:\n\n#{block(comment)}"
    }
  end

  # A screen comment is on what QA drives and the engineer builds, as a Fix on a screen finding is.
  defp rule(%ScreenComment{} = comment, _observation) do
    %{
      kind: :convention,
      roles: [:engineer, :qa],
      rule: clip(comment.body),
      why: "From a screen comment on #{screen_line(comment)}"
    }
  end

  # A comment on a finding corrects the role that raised it.
  defp rule(%FindingComment{finding: %Finding{} = finding} = comment, _observation) do
    quoted = comment.quote |> clip() |> String.split("\n") |> Enum.map_join("\n", &"> #{&1}")

    %{
      kind: :convention,
      roles: [raiser_role(finding)],
      rule: clip(comment.body),
      why: "From a finding comment on \"#{finding.title}\", its #{comment.label}:\n\n#{quoted}"
    }
  end

  defp rule(%PlanComment{target: :design} = comment, _observation) do
    %{
      kind: :design,
      roles: [:plan],
      rule: clip(comment.body),
      why: "From a design comment on #{comment.option_key}, #{element_line(comment)}:\n\n#{element_block(comment)}"
    }
  end

  # Every plan comment teaches Plan, which writes the ticket, the design and the plan; its kind says which.
  defp rule(%PlanComment{target: :ticket} = comment, _observation) do
    %{kind: :product, roles: [:plan], rule: clip(comment.body), why: line_why("a ticket", comment)}
  end

  defp rule(%PlanComment{target: :plan} = comment, _observation) do
    %{kind: :convention, roles: [:plan], rule: clip(comment.body), why: line_why("a plan", comment)}
  end

  # The review agent writes the next round's plan, so a comment on one teaches it.
  defp rule(%PlanComment{target: :fix_plan} = comment, _observation) do
    %{kind: :convention, roles: [:review_lead], rule: clip(comment.body), why: line_why("a fix round's plan", comment)}
  end

  defp rule(%Finding{kind: :screen} = finding, _observation) do
    Map.merge(%{kind: :convention, roles: [:engineer, :qa]}, finding_rule(finding, "Raised by QA"))
  end

  defp rule(%Finding{} = finding, _observation) do
    where = if finding.file, do: " on #{finding.file}", else: ""
    Map.merge(%{kind: :convention, roles: [:engineer, :review]}, finding_rule(finding, "Raised in review#{where}"))
  end

  # A bare answer such as "Yes" means nothing to a later run without the question it settled.
  defp rule(%Question{} = question, _observation) do
    %{kind: :decision, roles: [], rule: Learning.answer_rule(question.prompt, question.answer), why: nil}
  end

  # A finding's broken rule is what to do instead, where it names one; its title names what was wrong.
  defp finding_rule(%Finding{rule: rule} = finding, raised) when is_binary(rule) and rule != "" do
    %{rule: clip(rule), why: why(["#{raised} and sent to be fixed: #{finding.title}", finding.problem, finding.fix])}
  end

  defp finding_rule(%Finding{} = finding, raised) do
    %{
      rule: clip(finding.fix || finding.title),
      why: why(["#{raised} and sent to be fixed: #{finding.title}", finding.problem])
    }
  end

  defp line_why(document, %PlanComment{} = comment) do
    quoted = comment.element_text |> clip() |> String.split("\n") |> Enum.map_join("\n", &"> #{&1}")
    "From #{document} comment on #{comment.element_label}:\n\n#{quoted}"
  end

  defp raiser_role(%Finding{raised_by: :code_reviewer}), do: :review
  defp raiser_role(%Finding{raised_by: :explorer}), do: :qa
  defp raiser_role(%Finding{raised_by: :review_lead}), do: :review_lead

  defp why(parts), do: parts |> Enum.reject(&is_nil/1) |> Enum.join("\n\n")

  defp block(%DiffComment{context_text: context}) when is_binary(context) and context != "", do: context
  defp block(%DiffComment{line_text: line}), do: line

  defp screen_line(%ScreenComment{commit: commit} = comment) when is_binary(commit),
    do: "#{comment.label} (#{comment.key}), shot on #{String.slice(commit, 0, 7)}"

  defp screen_line(%ScreenComment{} = comment), do: "#{comment.label} (#{comment.key})"

  defp element_line(%PlanComment{element_text: "", element_tag: tag} = comment), do: "`#{comment.selector}` <#{tag}>"
  defp element_line(%PlanComment{} = comment), do: ~s(`#{comment.selector}` "#{comment.element_text}")

  # Enough of the element for an agent to recognize it, without crowding every brief the rule reaches.
  defp element_block(%PlanComment{capture: %{html: html}}) do
    cut = if String.length(html) > 2_000, do: "\n<!-- Rail cut the element's HTML here, at 2,000 characters. -->"
    "```html\n#{clip(html)}#{cut}\n```"
  end

  defp clip(text), do: String.slice(text, 0, 2_000)
end
