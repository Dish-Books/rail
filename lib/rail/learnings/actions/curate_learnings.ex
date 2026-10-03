defmodule Rail.Learnings.Actions.CurateLearnings do
  @moduledoc """
  The daily curator pass: what no pass has read, folded in one transaction into proposals, links and auto-activations, then a digest.
  A failed pass stamps nothing, so its observations go to the next one.
  """

  import Ecto.Query
  import Rail.Learnings.Utils.ApplyProposal
  import Rail.Learnings.Utils.BroadcastLearningsChanged
  import Rail.Learnings.Utils.EnqueueEmbedding
  import Rail.Learnings.Utils.EnqueuePullRequests
  import Rail.Learnings.Utils.RunCuratorRole
  import Rail.Learnings.Utils.WriteRulesFile

  alias Rail.Git
  alias Rail.Learnings
  alias Rail.Learnings.Schemas.CuratorPass
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Schemas.LearningProposal
  alias Rail.Learnings.Schemas.Observation
  alias Rail.Pipeline.Schemas.ReviewFinding
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Projects.Schemas.SlackChannel
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Slack

  @proposed [:add, :merge, :rewrite, :retire, :conflict, :promote]
  @auto_tasks 3

  @sighting_nouns %{
    diff_comment: {"diff comment", "diff comments"},
    review_finding: {"Fix decision", "Fix decisions"},
    qa_finding: {"Fix decision", "Fix decisions"},
    answer: {"answer", "answers"},
    pr_review_comment: {"PR comment", "PR comments"},
    pr_review: {"PR comment", "PR comments"},
    override: {"override", "overrides"},
    extraction: {"finished task", "finished tasks"}
  }

  @source_phrases %{
    diff_comment: "a diff comment",
    review_finding: "a Fix in review",
    qa_finding: "a Fix in QA",
    answer: "an answer"
  }

  @doc """
  Runs one pass over `project`. Returns `{:ok, pass}` as it finished, or
  `{:error, reason}` with the reason recorded on the pass.
  """
  def curate_learnings(%Project{id: project_id} = project) do
    last =
      Repo.one(
        from p in CuratorPass,
          where: p.project_id == ^project_id and not is_nil(p.finished_at),
          order_by: [desc: p.started_at],
          limit: 1
      )

    now = DateTime.utc_now()
    pass = Repo.insert!(%CuratorPass{project_id: project_id, started_at: now})
    since = if last, do: last.started_at, else: DateTime.shift(now, day: -1)
    checkout = Path.join(project.clone_path, ".worktrees/curator-#{pass.id}")

    outcome =
      try do
        run(project, pass, since, checkout)
      after
        _removed = Git.remove_worktree(project.clone_path, checkout)
      end

    case outcome do
      {:ok, folded} ->
        broadcast_learnings_changed(project_id)
        {:ok, digest(project, Repo.reload!(pass), since, folded)}

      {:error, reason} ->
        failed = pass |> Ecto.Changeset.change(error: inspect(reason)) |> Repo.update!()
        {:error, {reason, failed}}
    end
  end

  defp run(%Project{} = project, %CuratorPass{} = pass, since, checkout) do
    observations =
      Repo.all(
        from o in Observation,
          where: o.project_id == ^project.id and is_nil(o.curator_pass_id),
          order_by: [asc: o.inserted_at, asc: o.id],
          preload: [:actor, task: :issue]
      )

    dir = Path.join([Rail.scratch_root(), project.id, "learnings", "curator", pass.id])

    try do
      with {:ok, _queued} <- enqueue_pull_requests(project, since),
           {:ok, checkout} <- Git.checkout_detached_worktree(project, checkout),
           :ok <- write_files(project, dir, observations, since),
           {:ok, result} <- run_curator_role(project, dir, brief(project, dir, checkout)) do
        {:ok, fold(project, pass, observations, result)}
      end
    after
      File.rm_rf(dir)
    end
  end

  defp write_files(%Project{} = project, dir, observations, since) do
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    write_rules_file(project, Path.join(dir, "rules.md"))
    File.write!(Path.join(dir, "proposals.md"), proposals_file(project))
    File.write!(Path.join(dir, "observations.md"), observations_file(observations))
    File.write!(Path.join(dir, "broken.md"), broken_file(project, since))
    File.write!(Path.join(dir, "rejected.md"), rejected_file(project))
    :ok
  end

  defp proposals_file(%Project{id: project_id}) do
    pending =
      Repo.all(
        from p in LearningProposal,
          where: p.project_id == ^project_id and p.status == :pending,
          order_by: [asc: p.inserted_at],
          preload: :learning
      )

    entries =
      Enum.map(pending, fn %LearningProposal{learning: learning} = proposal ->
        "## #{proposal.id} · #{LearningProposal.action_label(proposal.action)} · rule #{learning.id} (#{learning.status})\n\n#{learning.rule}\n\nEvidence: #{Enum.join(proposal.evidence_ids, ", ")}\n"
      end)

    "# Proposals waiting on a person, with their drafts\n\n" <> Enum.join(entries, "\n")
  end

  defp observations_file(observations) do
    entries =
      Enum.map(observations, fn %Observation{} = observation ->
        task = if observation.task, do: " · #{observation.task.issue.identifier}", else: ""
        abandoned = if observation.abandoned, do: " · from an abandoned task", else: ""
        rule = if observation.learning_id, do: " · about rule #{observation.learning_id}", else: ""
        excerpt = if observation.excerpt, do: "\n\n```\n#{observation.excerpt}\n```", else: ""

        "## #{observation.id} · #{Observation.source_label(observation.source_kind)} · #{Observation.actor_label(observation)}#{task}#{abandoned}#{rule}\n\n#{observation.text}#{excerpt}\n"
      end)

    "# Observations no pass has read\n\n" <> Enum.join(entries, "\n")
  end

  defp broken_file(%Project{id: project_id}, since) do
    findings =
      Repo.all(
        from f in ReviewFinding,
          join: t in Task,
          on: t.id == f.task_id,
          where: t.project_id == ^project_id and not is_nil(f.rule_id) and is_nil(f.suppressed_by_id),
          where: f.inserted_at > ^since,
          order_by: [asc: f.inserted_at],
          preload: [task: :issue]
      )

    entries = Enum.map(findings, &"- Rule #{&1.rule_id} broken on #{&1.task.issue.identifier}: #{&1.title}")
    "# Findings that broke a rule since the last pass\n\n" <> Enum.join(entries, "\n") <> "\n"
  end

  defp rejected_file(%Project{id: project_id}) do
    month_ago = DateTime.shift(DateTime.utc_now(), day: -30)

    rejected =
      Repo.all(
        from p in LearningProposal,
          where: p.project_id == ^project_id and p.status == :rejected and p.decided_at > ^month_ago,
          order_by: [desc: p.decided_at],
          preload: :learning
      )

    entries = Enum.map(rejected, &"- #{LearningProposal.action_label(&1.action)}: #{&1.learning.rule}")
    "# Proposals people rejected in the last month\n\n" <> Enum.join(entries, "\n") <> "\n"
  end

  defp fold(%Project{id: project_id}, %CuratorPass{id: pass_id}, observations, result) do
    read = MapSet.new(observations, & &1.id)

    rules =
      Map.new(Repo.all(from l in Learning, where: l.project_id == ^project_id, select: {l.id, l.status}))

    {:ok, folded} =
      Repo.transaction(fn ->
        {proposals, _pending} =
          result["proposals"]
          |> List.wrap()
          |> Enum.reduce({[], pending(project_id)}, fn attrs, {proposals, pending} ->
            case propose(attrs, project_id, pass_id, read, rules, pending) do
              %LearningProposal{} = proposal -> {[proposal | proposals], MapSet.put(pending, same(proposal))}
              nil -> {proposals, pending}
            end
          end)

        proposals = Enum.reverse(proposals)

        linked = for attrs <- List.wrap(result["outcomes"]), proposal = link(attrs, project_id, read, rules), do: proposal

        activated =
          (proposals ++ linked)
          |> Enum.filter(&(&1.action == :add))
          |> Enum.uniq_by(& &1.id)
          |> Enum.filter(&backed?/1)
          |> Enum.flat_map(&activate/1)

        Repo.update_all(from(o in Observation, where: o.id in ^MapSet.to_list(read)), set: [curator_pass_id: pass_id])
        Repo.update_all(from(p in CuratorPass, where: p.id == ^pass_id), set: [finished_at: DateTime.utc_now()])

        %{proposals: proposals, activated: activated}
      end)

    folded
  end

  # The curator's word is an agent's, so a proposal naming anything outside this
  # project, or anything this pass did not read, is dropped whole, as is one already waiting.
  defp propose(%{"action" => action} = attrs, project_id, pass_id, read, rules, pending) when is_binary(action) do
    action = Enum.find(@proposed, &(Atom.to_string(&1) == action))
    subject = attrs["learning"]
    targets = strings(attrs["targets"])
    evidence = strings(attrs["evidence"])

    with true <- action != nil,
         true <- Enum.all?(evidence, &MapSet.member?(read, &1)),
         true <- Enum.all?(targets, &Map.has_key?(rules, &1)),
         false <- MapSet.member?(pending, same(action, subject, targets)),
         {:ok, learning} <- subject(action, subject, attrs, project_id, rules, targets) do
      proposal =
        %LearningProposal{project_id: project_id}
        |> LearningProposal.changeset(%{
          action: action,
          title: string(attrs["title"]),
          summary: string(attrs["summary"]),
          learning_id: learning.id,
          target_ids: targets,
          evidence_ids: evidence,
          promote_to: Enum.find(LearningProposal.promote_targets(), &(Atom.to_string(&1) == attrs["promote_to"])),
          curator_pass_id: pass_id
        })
        |> Repo.insert!()

      # A sighting that already made or joined a rule stays that rule's source; the proposal keeps it as evidence.
      if action == :add do
        Repo.update_all(from(o in Observation, where: o.id in ^evidence and is_nil(o.learning_id)),
          set: [learning_id: learning.id]
        )
      end

      proposal
    else
      _foreign_or_malformed -> nil
    end
  end

  defp propose(_malformed, _project_id, _pass_id, _read, _rules, _pending), do: nil

  defp pending(project_id) do
    from(p in LearningProposal, where: p.project_id == ^project_id and p.status == :pending)
    |> Repo.all()
    |> MapSet.new(&same/1)
  end

  # What makes two proposals the same: a merge or rewrite drafts a new rule each time, so its targets are what it is about.
  defp same(%LearningProposal{action: action, target_ids: targets}) when action in [:merge, :rewrite],
    do: same(action, nil, targets)

  defp same(%LearningProposal{action: action, learning_id: id, target_ids: targets}), do: same(action, id, targets)

  # An add drafting a new rule has nothing to be the same as but its wording, which an agent rewords.
  defp same(:add, nil, _targets), do: make_ref()
  defp same(action, id, targets), do: {action, id, MapSet.new(targets)}

  # An add names a provisional rule to confirm, or drafts a new one; so do merge and rewrite.
  defp subject(:add, id, _attrs, _project_id, rules, _targets) when is_binary(id) do
    if Map.get(rules, id) == :provisional, do: {:ok, Repo.get!(Learning, id)}, else: :foreign
  end

  defp subject(action, nil, attrs, project_id, _rules, targets) when action in [:add, :merge, :rewrite] do
    changeset = Learning.changeset(%Learning{project_id: project_id, status: :proposed}, draft(attrs))

    cond do
      action != :add and targets == [] -> :no_targets
      changeset.valid? -> insert_draft(changeset)
      true -> :invalid_draft
    end
  end

  defp subject(action, id, _attrs, _project_id, rules, targets)
       when action in [:retire, :conflict, :promote] and is_binary(id) do
    cond do
      Map.get(rules, id) not in [:active, :provisional] -> :foreign
      action == :conflict and targets == [] -> :no_targets
      true -> {:ok, Repo.get!(Learning, id)}
    end
  end

  defp subject(_action, _id, _attrs, _project_id, _rules, _targets), do: :malformed

  defp insert_draft(changeset) do
    draft = Repo.insert!(changeset)
    enqueue_embedding([draft])
    {:ok, draft}
  end

  defp draft(attrs) do
    roles =
      for role <- strings(attrs["roles"]), found = Enum.find(Learning.roles(), &(Atom.to_string(&1) == role)), do: found

    %{
      rule: string(attrs["rule"]),
      why: string(attrs["why"]),
      kind: Enum.find(Learning.kinds(), &(Atom.to_string(&1) == attrs["kind"])),
      roles: roles,
      path_glob: string(attrs["path_glob"])
    }
  end

  # A sighting of a pending draft is more evidence for its add, which is what can activate it.
  defp link(%{"observation" => id, "outcome" => "link", "learning" => learning_id}, project_id, read, rules)
       when is_binary(id) and is_binary(learning_id) do
    if MapSet.member?(read, id) and Map.has_key?(rules, learning_id) do
      Repo.update_all(from(o in Observation, where: o.id == ^id), set: [learning_id: learning_id])

      case Repo.one(
             from p in LearningProposal,
               where: p.project_id == ^project_id and p.learning_id == ^learning_id,
               where: p.action == :add and p.status == :pending,
               limit: 1
           ) do
        %LearningProposal{} = proposal ->
          proposal |> Ecto.Changeset.change(evidence_ids: Enum.uniq([id | proposal.evidence_ids])) |> Repo.update!()

        nil ->
          nil
      end
    end
  end

  defp link(_dismissed_or_malformed, _project_id, _read, _rules), do: nil

  defp backed?(%LearningProposal{learning_id: learning_id, evidence_ids: evidence}) do
    tasks =
      Repo.one(
        from o in Observation,
          where: o.id in ^evidence or o.learning_id == ^learning_id,
          where: not o.abandoned and not is_nil(o.task_id),
          select: count(o.task_id, :distinct)
      )

    tasks >= @auto_tasks
  end

  # A rule retired since its add was proposed stays retired.
  defp activate(%LearningProposal{id: id} = proposal) do
    case apply_proposal(Scope.for_system(), proposal) do
      {:ok, _applied} ->
        Repo.update_all(from(p in LearningProposal, where: p.id == ^id),
          set: [status: :approved, decided_at: DateTime.utc_now()]
        )

        [Repo.get!(Learning, proposal.learning_id)]

      {:error, :retired} ->
        []
    end
  end

  defp strings(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp strings(_missing), do: []

  defp string(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp string(_missing), do: nil

  defp digest(%Project{} = project, %CuratorPass{} = pass, since, %{proposals: proposals, activated: activated}) do
    provisional =
      Repo.all(
        from l in Learning,
          where: l.project_id == ^project.id and l.status == :provisional and l.inserted_at > ^since,
          order_by: [asc: l.inserted_at],
          preload: [observations: ^from(o in Observation, order_by: [asc: o.inserted_at], preload: [task: :issue])]
      )

    with true <- activated != [] or proposals != [] or provisional != [],
         %SlackChannel{} = channel <- triage_channel(project),
         {:ok, ts} <-
           Slack.post_channel_message(
             channel.slack_workspace,
             channel.external_id,
             digest_text(project, pass, activated, provisional)
           ),
         {:ok, permalink} <- Slack.permalink(channel.slack_workspace, channel.external_id, ts) do
      posted = pass |> Ecto.Changeset.change(digest_permalink: permalink) |> Repo.update!()
      broadcast_learnings_changed(project.id)
      posted
    else
      _quiet_or_unposted -> pass
    end
  end

  defp triage_channel(%Project{id: project_id}) do
    Repo.one(
      from c in SlackChannel,
        where: c.project_id == ^project_id,
        order_by: [asc: c.inserted_at, asc: c.id],
        limit: 1,
        preload: :slack_workspace
    )
  end

  defp digest_text(%Project{} = project, %CuratorPass{} = pass, activated, provisional) do
    counts = Learnings.count_learnings(project_id: project.id)

    pending =
      Repo.all(
        from p in LearningProposal,
          where: p.project_id == ^project.id and p.status == :pending,
          group_by: p.action,
          select: {p.action, count(p.id)}
      )

    sections = [
      "*Learnings for #{project.name}*, curator run of #{Calendar.strftime(pass.started_at, "%b %-d")}",
      activated_section(activated),
      if(counts.review > 0, do: "*To review #{counts.review}:* #{Enum.map_join(pending, ", ", &pending_label/1)}"),
      provisional_section(provisional),
      "<#{RailWeb.Endpoint.url()}/learnings|Open Learnings in Rail>"
    ]

    sections |> Enum.reject(&is_nil/1) |> Enum.join("\n")
  end

  defp activated_section([]), do: nil

  defp activated_section(activated) do
    activated = Repo.preload(activated, :observations)
    bullets = Enum.map(activated, &"• #{&1.rule} (#{sightings(&1.observations)})")
    Enum.join(["*Auto-activated #{length(activated)}*" | bullets], "\n")
  end

  defp provisional_section([]), do: nil

  defp provisional_section(provisional) do
    from =
      provisional
      |> Enum.flat_map(&Enum.take(&1.observations, 1))
      |> Enum.map(fn observation ->
        on = if observation.task, do: " on #{observation.task.issue.identifier}", else: ""
        "#{source_phrase(observation.source_kind)}#{on}"
      end)

    "*Provisional since the last run #{length(provisional)}:* from #{Enum.join(from, ", ")}"
  end

  defp pending_label({:add, count}), do: "#{count} new"
  defp pending_label({:override, count}), do: "#{count} flagged by an override"
  defp pending_label({action, count}), do: "#{count} #{action}"

  defp sightings(observations) do
    observations
    |> Enum.frequencies_by(& &1.source_kind)
    |> Enum.map_join(", ", fn {kind, count} ->
      {one, many} = Map.fetch!(@sighting_nouns, kind)
      if count == 1, do: "1 #{one}", else: "#{count} #{many}"
    end)
  end

  defp source_phrase(kind), do: Map.get(@source_phrases, kind, "a sighting")

  defp brief(%Project{} = project, dir, checkout) do
    result = Path.join(dir, "result.json")

    String.trim("""
    You are #{project.name}'s curator. Once a day you read what Rail has seen since your last pass and propose how the project's rules should change. People decide; you propose. The one thing that takes effect without a person is an add you back with sightings from three or more tasks, which Rail activates itself.

    Everything is in #{dir}:

    - observations.md, every sighting no pass has read: corrections people made, pull request comments, and lessons distilled from finished tasks.
    - rules.md, the active and provisional rules, each under its id.
    - proposals.md, what is already waiting on a person, with each draft's rule id.
    - broken.md, findings raised against a rule a run was given anyway.
    - rejected.md, what people turned down this month. Do not propose it again.

    #{checkout} is a checkout of the default branch. Read it to check whether the code a rule names still exists. Change nothing in it, and write no file but #{result}.

    Every rule is an instruction to every run that meets it, so a bad one costs every run it reaches and a missing one costs a person correcting the same thing again. A good rule:

    - is one instruction an agent can follow without having seen the task it came from: "context functions take the scope first", not "the scope was wrong on the last task";
    - is scoped as narrowly as it holds, to the roles that act on it and, where it is about some files and not others, a path glob;
    - says in its why what breaks without it, so an agent can tell when it does not apply.

    Weigh the evidence before you propose:

    - Every observation needs an outcome. Link it to the rule or pending draft it is another sighting of, make it the evidence of a new proposal, or dismiss it as one-off.
    - A sighting from three tasks is a pattern and from one an anecdote. Count a sighting as evidence only when it is the same lesson, since Rail activates an add on its own once its evidence spans three tasks.
    - A sighting from an abandoned task counts for less: the work may have been wrong for reasons no review saw.
    - A rule given to runs and broken anyway is not working. Rewrite it so it is followed, or promote it out of the knowledge base to somewhere it is enforced or always read.
    - Propose a calibration rule, which says what review should not raise, only when people dismissed the same kind of finding again and again.

    Write #{result} with a heredoc, the closing JSON line at column zero:

    cat > #{result} <<'JSON'
    {
      "outcomes": [
        {"observation": "obs_...", "outcome": "link", "learning": "lrn_..."},
        {"observation": "obs_...", "outcome": "dismiss"}
      ],
      "proposals": [
        {"action": "add", "title": "one line saying what this changes", "summary": "a few words on why, such as the tasks it came from", "rule": "the rule, as an instruction", "why": "why it holds", "kind": "convention", "roles": ["engineer", "review"], "path_glob": null, "evidence": ["obs_..."]},
        {"action": "add", "learning": "lrn_...", "summary": "confirms a provisional rule", "evidence": ["obs_..."]},
        {"action": "merge", "targets": ["lrn_...", "lrn_..."], "title": "...", "rule": "...", "why": "...", "kind": "convention", "roles": [], "evidence": []},
        {"action": "rewrite", "targets": ["lrn_..."], "title": "...", "rule": "...", "why": "...", "kind": "decision", "roles": [], "evidence": []},
        {"action": "retire", "learning": "lrn_...", "summary": "code gone in #109", "evidence": []},
        {"action": "conflict", "learning": "lrn_...", "targets": ["lrn_..."], "summary": "RAIL-46 and RAIL-63 disagree", "evidence": []},
        {"action": "promote", "learning": "lrn_...", "promote_to": "credo_check", "summary": "broken 3 times", "evidence": []}
      ]
    }
    JSON

    - An observation you make the evidence of a proposal needs no outcome of its own.
    - `kind` is convention, decision, environment, product, design, qa or calibration. A calibration rule says what review should not raise.
    - `roles` are product, design, architect, engineer, review, qa, demo and triage, and an empty list means every role. `path_glob` scopes a rule to files, such as `lib/rail_web/**`.
    - Retire a rule whose code is gone, or that a newer decision contradicts. Flag a conflict where two rules disagree. Promote a rule broken again and again to `credo_check` (a lint check the project runs), `role_prompt` (the prompt of the roles it is for) or `claude_md` (a line in the repository's CLAUDE.md).
    - Ids are only ever ones from these files. A proposal naming any other is dropped.
    - `{"outcomes": [], "proposals": []}` is right when there was nothing to read.
    """)
  end
end
