defmodule RailWeb.Live.ReviewStage do
  @moduledoc """
  Review, read the way Plan lists its own items: a slim rail of Findings, Diff, Screens, Demo and Browser
  beside the picked item's pane. Findings is the list beside one finding, with what the run is doing above
  them while it works or waits; ruling moves on to the next finding, and Start fix round, or Finish review,
  is the list's footer. Diff is the branch, or one commit of it, which a finding's commits open. Screens
  sets each screen state's latest shot beside an earlier one, Demo plays the latest recording with its
  walkthrough and says when the branch has moved past it, and Browser watches any tab the explorers and
  the demo recorder have open.
  """
  use RailWeb, :live_component

  alias Rail.Git
  alias Rail.Learnings
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.FindingEvidence
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Pipeline.Turn
  alias Rail.Tools
  alias Rail.Users
  alias RailWeb.Live.DiffView

  @double_click_ms 400

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:error, fn -> nil end)
      |> assign_new(:item, fn -> :findings end)
      |> assign_new(:selected_key, fn -> nil end)
      |> assign_new(:advanced_to, fn -> nil end)
      |> assign_new(:filed_index, fn -> 0 end)
      |> assign_new(:browser, fn -> nil end)
      |> assign_new(:diff_open, fn -> nil end)
      |> assign_new(:diff_file, fn -> nil end)
      |> assign_new(:screen_open, fn -> nil end)
      |> assign_new(:screen_earlier, fn -> nil end)
      |> load()

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="review-stage" data-qa="review-stage" class="contents">
      <.task_layout
        task={@task}
        run={@run}
        stage_run={@stage_run}
        line={@line}
        title={@task.issue.title}
        flush
      >
        <:breadcrumb :if={@breadcrumb != []}>{render_slot(@breadcrumb)}</:breadcrumb>
        <:tabs>{render_slot(@tabs)}</:tabs>
        <:actions>{render_slot(@actions)}</:actions>

        <:alerts :if={@error}>
          <p id="review-error" data-qa="review_error" class="text-xs text-red-600 dark:text-red-500">
            {@error}
          </p>
        </:alerts>

        <div class="@container h-full">
          <div class="h-full flex flex-col @xl:flex-row min-h-0">
            <.review_items items={@items} picked={@item} target={@myself} />

            <div id="review-pane" data-item={@item} class="flex-1 min-w-0 min-h-0 flex flex-col">
              <.review_status
                :if={
                  @item == :findings and
                    @phase in [:round, :fixing, :ci, :ci_failed, :finished]
                }
                phase={@phase}
                round={@round}
                sha={@sha}
                counts={@counts}
                agents={@agents}
                tail={@tail}
                pr_number={@task.pr_number}
              />

              <div :if={@item == :findings} class="@container flex-1 min-h-0">
                <div class="h-full flex flex-col @2xl:flex-row min-h-0">
                  <.finding_list
                    findings={@findings}
                    selected_key={@selected_key}
                    running={@phase == :round}
                    tally={@tally}
                    button={@button}
                    target={@myself}
                  />
                  <.finding_detail
                    :if={@selected}
                    finding={@selected}
                    position={@position}
                    count={length(@findings)}
                    decidable={@approvable and @phase not in [:round, :fixing, :ci, :finished]}
                    running={@phase == :round}
                    hunk={@hunk}
                    filed={@filed}
                    filed_index={@filed_index}
                    labels={@labels}
                    names={@names}
                    viewer_id={@current_scope.user && @current_scope.user.id}
                    suppressor={@suppressor}
                    neighbours={@neighbours}
                    target={@myself}
                  />
                  <p
                    :if={@selected == nil}
                    id="review-no-findings"
                    data-qa="review_no_findings"
                    class="flex-1 p-8 text-sm text-slate-500 dark:text-slate-400"
                  >
                    {if @phase == :round,
                      do: "Findings appear here as the round saves them.",
                      else: "No findings."}
                  </p>
                </div>
              </div>

              <div :if={@item == :diff} class="flex-1 min-w-0 min-h-0">
                <.live_component
                  module={DiffView}
                  id="diff-view"
                  task={@task}
                  run={@run}
                  agent="Review lead"
                  current_scope={@current_scope}
                  focus_file={@diff_file}
                  open={@diff_open}
                />
              </div>

              <.screen_compare
                :if={@item == :screens}
                task_id={@task.id}
                screens={@screens}
                labels={@labels}
                open={@screen_open}
                earlier={@screen_earlier}
                target={@myself}
              />

              <.demo_player
                :if={@item == :demo}
                task={@task}
                demo={@demo}
                beats={@beats}
                recorded={@recorded}
                recording={@recording}
                stale={@stale}
                rerecordable={@approvable and not Run.running?(@run)}
                target={@myself}
              />

              <.browser_picker
                :if={@item == :browser}
                sessions={@sessions}
                picked={@browser}
                url={@url}
                beats={length(@beats)}
                target={@myself}
              />
            </div>
          </div>
        </div>

        <:sidebar>{render_slot(@sidebar)}</:sidebar>
      </.task_layout>
    </div>
    """
  end

  @impl true
  def handle_event("pick_item", %{"item" => item}, socket) do
    socket = socket |> assign(:item, item(item)) |> load()
    {:noreply, socket}
  end

  # A finding's commit opens in the Diff item at the finding's file; none is the whole branch.
  def handle_event("open_diff", params, socket) do
    socket =
      socket
      |> assign(:item, :diff)
      |> assign(:diff_open, %{commit: params["commit"], at: System.unique_integer([:positive])})
      |> assign(:diff_file, params["file"])
      |> load()

    {:noreply, socket}
  end

  # Nothing is picked yet, so the shot set beside the latest is the one just before it.
  def handle_event("open_screen", %{"key" => key}, socket) do
    socket = socket |> assign(:screen_open, key) |> assign(:screen_earlier, nil)
    {:noreply, socket}
  end

  def handle_event("pick_earlier", %{"index" => index}, socket) do
    socket = assign(socket, :screen_earlier, String.to_integer(index))
    {:noreply, socket}
  end

  def handle_event("close_screen", _params, socket) do
    socket = socket |> assign(:screen_open, nil) |> assign(:screen_earlier, nil)
    {:noreply, socket}
  end

  def handle_event("open_finding", %{"key" => key}, socket) do
    socket = socket |> assign(:item, :findings) |> assign(:selected_key, key) |> assign(:filed_index, 0) |> load()
    {:noreply, socket}
  end

  def handle_event("record_demo", _params, socket) do
    case Pipeline.record_demo(socket.assigns.current_scope, socket.assigns.task) do
      {:ok, _sent, _run} ->
        send(self(), :task_changed)
        {:noreply, assign(socket, :error, nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :error, message_for(reason))}
    end
  end

  def handle_event("pick_browser", %{"name" => name}, socket) do
    socket = socket |> assign(:browser, name) |> load()
    {:noreply, socket}
  end

  def handle_event("select_finding", %{"key" => key}, socket) do
    socket = socket |> assign(:selected_key, key) |> assign(:filed_index, 0) |> load()
    {:noreply, socket}
  end

  def handle_event("select_evidence", %{"index" => index}, socket) do
    socket = assign(socket, :filed_index, String.to_integer(index))
    {:noreply, socket}
  end

  def handle_event("decide", %{"key" => key, "decision" => decision}, socket) do
    finding = Enum.find(socket.assigns.findings, &(&1.key == key))

    # Judged before the ruling, since after it every finding looks decided and a
    # changed ruling would move the reader on too.
    selected_key =
      if Finding.undecided?(finding),
        do: (next_undecided(socket.assigns.findings, finding) || finding).key,
        else: socket.assigns.selected_key

    socket =
      with false <- double_click?(socket.assigns.advanced_to, key),
           {:ok, _decided} <- Pipeline.decide_finding(socket.assigns.current_scope, finding, decision(decision)) do
        socket
        |> assign(:error, nil)
        |> assign(:selected_key, selected_key)
        |> assign(:filed_index, 0)
        |> assign(:advanced_to, if(selected_key != key, do: {selected_key, System.monotonic_time(:millisecond)}))
        |> load()
      else
        true -> socket
        {:error, reason} -> assign(socket, :error, message_for(reason))
      end

    {:noreply, socket}
  end

  def handle_event("start_fix_round", _params, socket) do
    case Pipeline.start_fix_round(socket.assigns.run) do
      {:ok, _run} ->
        send(self(), :task_changed)
        {:noreply, assign(socket, :error, nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :error, message_for(reason))}
    end
  end

  # Everything the open item shows is read off the rows and the disk again; what only one item needs is
  # read only while it is the one open.
  defp load(socket) do
    %{task: task, run: run} = socket.assigns
    findings = Pipeline.list_findings(task)
    passes = Pipeline.read_review(task)
    ci = Pipeline.get_ci_status(run)
    phase = phase(run, task, passes, findings, ci)
    counts = counts(findings)
    beats = Pipeline.list_demo_beats(task)
    recording = Tools.get_browser_recording(task) != nil
    sessions = sessions(task, run, recording)
    browser = picked_browser(sessions, socket.assigns.browser)
    selected = Enum.find(findings, List.first(findings), &(&1.key == socket.assigns.selected_key))

    socket
    |> assign(:findings, findings)
    |> assign(:phase, phase)
    |> assign(:round, round(phase, passes))
    |> assign(:sha, ci_sha(ci))
    |> assign(:counts, counts)
    |> assign(:tail, if(ci, do: ci.tail, else: []))
    |> assign(
      :agents,
      if(socket.assigns.item == :findings and phase in [:round, :fixing], do: agents(run), else: [])
    )
    |> assign(:tally, tally(phase, counts, findings, passes))
    |> assign(:button, button(phase, counts, passes, socket.assigns.approvable))
    |> assign_branch(passes)
    |> assign(:beats, beats)
    |> assign(:recorded, Task.demo_recorded?(task))
    |> assign(:recording, recording)
    |> assign(:sessions, sessions)
    |> assign(:browser, browser)
    |> assign(:url, browser && socket.assigns.item == :browser && Tools.get_browser_url(task, browser))
    |> assign_items()
    |> assign_selected(selected, findings)
    |> watch(browser)
  end

  # The branch's commits label each finding's and screen's commit, count the Diff item and date the demo.
  # The commits each round read are what tell the engineer's apart from each fix round's.
  defp assign_branch(%{assigns: %{task: task}} = socket, passes) do
    history = Git.load_branch_history(task, for(%{head: head} <- passes, is_binary(head), do: head))
    demo = Pipeline.read_demo(task)

    socket
    |> assign(:demo, demo)
    |> assign(:history, history)
    |> assign(:labels, Map.new(history.commits, &{&1.sha, &1.label}))
    |> assign(:screens, Pipeline.list_screens(task))
    |> assign(:stale, stale(demo, history))
  end

  # The page holds the subscription a frame arrives on, so it is told which browser is being watched.
  defp watch(socket, browser) do
    watched = if socket.assigns.item == :browser, do: browser
    send(self(), {:watch_browser, watched})
    socket
  end

  defp assign_selected(socket, nil, _findings) do
    socket
    |> assign(:selected, nil)
    |> assign(:selected_key, nil)
    |> assign(:position, 0)
    |> assign(:neighbours, %{previous: nil, next: nil})
    |> assign(:hunk, nil)
    |> assign(:filed, [])
    |> assign(:names, %{})
    |> assign(:suppressor, nil)
  end

  defp assign_selected(socket, %Finding{} = selected, findings) do
    index = Enum.find_index(findings, &(&1.key == selected.key))
    open? = socket.assigns.item == :findings

    socket
    |> assign(:selected, selected)
    |> assign(:selected_key, selected.key)
    |> assign(:position, index + 1)
    |> assign(:neighbours, %{
      previous: if(index > 0, do: Enum.at(findings, index - 1).key),
      next: if(index < length(findings) - 1, do: Enum.at(findings, index + 1).key)
    })
    |> assign(:hunk, if(open?, do: hunk(socket, selected)))
    |> assign(:filed, if(open?, do: filed(socket, selected), else: []))
    |> assign(:names, if(open?, do: names(socket, selected), else: %{}))
    |> assign(:suppressor, if(open?, do: suppressor(selected)))
  end

  defp assign_items(socket) do
    %{phase: phase, counts: counts, sessions: sessions} = socket.assigns

    findings = %{
      key: :findings,
      label: "Findings",
      icon: "pi-list-checks",
      picked_icon: "pi-list-checks-fill",
      state: findings_state(phase, counts, socket.assigns),
      badge: if(phase not in [:round, :fixing, :ci] and counts.undecided > 0, do: counts.undecided),
      dot: if(phase in [:round, :fixing, :ci], do: :running),
      mark:
        cond do
          phase == :finished -> :done
          phase == :ci_failed -> :failed
          true -> nil
        end
    }

    diff = %{
      key: :diff,
      label: "Diff",
      icon: "pi-git-diff",
      picked_icon: "pi-git-diff-fill",
      state: diff_state(socket.assigns.history),
      badge: nil,
      dot: nil,
      mark: nil
    }

    screens = %{
      key: :screens,
      label: "Screens",
      icon: "pi-images",
      picked_icon: "pi-images-fill",
      state: screens_state(socket.assigns.screens),
      badge: nil,
      dot: nil,
      mark: nil
    }

    demo = %{
      key: :demo,
      label: "Demo",
      icon: "pi-video-camera",
      picked_icon: "pi-video-camera-fill",
      state: demo_state(socket.assigns),
      badge: nil,
      dot: if(socket.assigns.recording, do: :recording),
      mark: if(socket.assigns.stale && not socket.assigns.recording, do: :stale)
    }

    browser = %{
      key: :browser,
      label: "Browser",
      icon: "pi-browsers",
      picked_icon: "pi-browsers-fill",
      state: browser_state(sessions),
      badge: nil,
      dot:
        cond do
          Enum.any?(sessions, &(&1.state == :recording)) -> :recording
          Enum.any?(sessions, &(&1.state == :driving)) -> :running
          true -> nil
        end,
      mark: nil
    }

    assign(socket, :items, [findings, diff, screens, demo, browser])
  end

  # What the run is doing, read off the run, its CI and the passes it saved. A run working with a Fix
  # finding the last pass read and nothing committed since is fixing; any other working run is a round.
  defp phase(%Run{} = run, %Task{} = task, passes, findings, ci) do
    cond do
      match?(%{state: :running}, ci) -> :ci
      Run.running?(run) and fixing?(task, passes, findings) -> :fixing
      Run.running?(run) -> :round
      passes != [] and List.last(passes).finished_at != nil -> :finished
      match?(%{state: :failed, failures: failures} when failures >= 3, ci) -> :ci_failed
      true -> :ruling
    end
  end

  defp fixing?(%Task{} = task, [_first | _rest] = passes, findings) do
    Enum.any?(findings, &Finding.outstanding?/1) and
      List.last(passes).head in [nil, (Git.branch_fingerprint(task.worktree_path) || %{})[:head_sha]]
  end

  defp fixing?(%Task{}, [], _findings), do: false

  defp round(:round, passes), do: length(passes) + 1
  defp round(_phase, passes), do: max(length(passes), 1)

  defp counts(findings) do
    %{
      total: length(findings),
      undecided: Enum.count(findings, &Finding.undecided?/1),
      fix: Enum.count(findings, &Finding.outstanding?/1),
      fixed: Enum.count(findings, &(&1.status == :fixed)),
      dismissed: Enum.count(findings, &(Finding.state(&1) in [:dismissed, :suppressed]))
    }
  end

  defp tally(:round, counts, _findings, passes),
    do: "#{counts.total} so far · rule once round #{length(passes) + 1} finishes"

  defp tally(phase, counts, _findings, _passes) when phase in [:fixing, :ci],
    do: said([{counts.fix, "fixing"}, {counts.fixed, "fixed"}, {counts.dismissed, "not fixing"}])

  defp tally(_phase, %{total: 0}, _findings, _passes), do: "No findings"

  defp tally(_phase, counts, _findings, _passes) do
    said([
      {counts.undecided, "to rule"},
      {counts.fix, "to fix"},
      {counts.fixed, "fixed"},
      {counts.dismissed, "not fixing"}
    ])
  end

  defp said(parts) do
    parts
    |> Enum.reject(fn {count, _word} -> count == 0 end)
    |> Enum.map_join(" · ", fn {count, word} -> "#{count} #{word}" end)
  end

  # Disabled until every finding is ruled; gone while a fix round runs and once nothing is left.
  defp button(:round, _counts, passes, _approvable) do
    round = length(passes) + 1
    %{label: "Start fix round #{round}", icon: "pi-wrench", disabled: true, title: "Round #{round} is still running"}
  end

  defp button(phase, _counts, _passes, _approvable) when phase in [:fixing, :ci, :finished], do: nil
  defp button(_phase, _counts, [], _approvable), do: nil
  defp button(_phase, _counts, _passes, false), do: nil

  defp button(_phase, %{undecided: undecided}, passes, true) when undecided > 0 do
    %{
      label: "Start fix round #{length(passes)}",
      icon: "pi-wrench",
      disabled: true,
      title: "Rule on #{undecided} more first"
    }
  end

  # A fix whose commit fails CI is still waiting, so the review cannot finish on it.
  defp button(:ci_failed, %{fix: 0}, _passes, true),
    do: %{label: "Finish review", icon: "pi-check", disabled: true, title: "CI failed on the fix commit"}

  defp button(_phase, %{fix: 0}, _passes, true),
    do: %{label: "Finish review", icon: "pi-check", disabled: false, title: nil}

  defp button(_phase, _counts, passes, true),
    do: %{label: "Start fix round #{length(passes)}", icon: "pi-wrench", disabled: false, title: nil}

  defp findings_state(:round, _counts, assigns), do: "Round #{assigns.round} running"
  defp findings_state(:fixing, _counts, assigns), do: "Fix round #{assigns.round} running"
  defp findings_state(:ci, _counts, %{sha: sha}), do: "CI running" <> if(sha, do: " on #{sha}", else: "")
  defp findings_state(:ci_failed, _counts, %{sha: sha}), do: "CI failed" <> if(sha, do: " on #{sha}", else: "")
  defp findings_state(:finished, _counts, _assigns), do: "Nothing left to rule"

  defp findings_state(:ruling, counts, _assigns) do
    case said([{counts.undecided, "to rule"}, {counts.fix, "to fix"}]) do
      "" -> "Nothing to rule"
      state -> state
    end
  end

  defp diff_state(%{commits: []}), do: "No commits yet"

  defp diff_state(history),
    do: "#{plural(length(history.commits), "commit")} · +#{history.additions} -#{history.deletions}"

  defp screens_state([]), do: "No screens yet"

  defp screens_state(screens) do
    latest = screens |> Enum.map(&List.last(&1.shots)) |> Enum.max_by(& &1.taken_at, DateTime)
    on = if latest.commit, do: " · on #{String.slice(latest.commit, 0, 7)}", else: ""
    "#{plural(length(screens), "screen")}#{on}"
  end

  defp demo_state(%{recording: true, beats: [_one]}), do: "Recording · 1 beat said so far"
  defp demo_state(%{recording: true, beats: beats}), do: "Recording · #{length(beats)} beats said so far"

  defp demo_state(%{recorded: true, stale: %{} = stale}), do: stale_text(stale)

  defp demo_state(%{recorded: true, demo: %{commit: commit}}) when is_binary(commit),
    do: "Recorded on #{String.slice(commit, 0, 7)}"

  defp demo_state(%{recorded: true}), do: "Recorded"
  defp demo_state(_none), do: "None recorded"

  defp browser_state([]), do: "No browsers open"

  defp browser_state(sessions) do
    recording = Enum.count(sessions, &(&1.state == :recording))
    driving = Enum.count(sessions, &(&1.state == :driving))
    count = if length(sessions) == 1, do: "1 browser", else: "#{length(sessions)} browsers"

    cond do
      recording > 0 -> "#{recording} recording"
      driving > 0 -> "#{count} · #{driving} driving"
      true -> "#{count} · idle"
    end
  end

  # A tab is driving while the run works and Rail holds it, and the demo recorder's is recording while filmed.
  defp sessions(%Task{} = task, %Run{} = run, recording) do
    running = Run.running?(run)

    for session <- Tools.list_browser_sessions(task) do
      state =
        cond do
          recording and session.name == "demo" -> :recording
          running and Tools.get_browser_session(task, session.name) != nil -> :driving
          true -> :idle
        end

      %{name: session.name, account: session.account, state: state}
    end
  end

  defp picked_browser(sessions, picked) do
    if Enum.any?(sessions, &(&1.name == picked)), do: picked, else: sessions |> List.first() |> then(&(&1 && &1.name))
  end

  # The subagents of the turn the run is on, by role, with the work the lead gave each.
  defp agents(%Run{} = run) do
    case Tools.list_os_processes(run_id: run.id, kind: :agent) do
      [latest | _earlier] ->
        run
        |> Pipeline.list_run_events(os_process_id: latest.id)
        |> Enum.map(& &1.line)
        |> Pipeline.parse_transcript()
        |> Enum.flat_map(fn
          %Turn{author: :subagent} = turn -> [agent(turn)]
          %Turn{} -> []
        end)

      [] ->
        []
    end
  end

  defp agent(%Turn{label: label, content: content, status: status}) do
    {name, work} = subagent_name(label, content) || {label, content}

    %{name: name, work: work, running: status == :running}
  end

  # How many of the branch's commits came after the one the demo was recorded on, counted when the tab draws.
  # A commit the branch no longer has, after a rebase, is behind by a count nobody can give.
  defp stale(%{commit: commit}, %{commits: [_latest | _earlier] = commits}) when is_binary(commit) do
    case Enum.find_index(commits, &(&1.sha == commit)) do
      0 -> nil
      behind when is_integer(behind) -> %{commit: commit, behind: behind}
      nil -> %{commit: commit, behind: nil}
    end
  end

  defp stale(_demo, _history), do: nil

  defp stale_text(%{commit: commit, behind: nil}),
    do: "Recorded on #{String.slice(commit, 0, 7)}, which the branch no longer has; may be out of date"

  defp stale_text(%{commit: commit, behind: behind}),
    do: "Recorded on #{String.slice(commit, 0, 7)}, #{plural(behind, "commit")} ago; may be out of date"

  defp plural(1, word), do: "1 #{word}"
  defp plural(count, word), do: "#{count} #{word}s"

  defp ci_sha(%{os_process: %{head_sha: sha}}) when is_binary(sha), do: String.slice(sha, 0, 7)
  defp ci_sha(_no_ci), do: nil

  # The code a finding points at is read off the worktree, its whole range marked.
  defp hunk(socket, %Finding{file: file, line: line} = finding) when is_binary(file) do
    case Git.load_diff_hunk(socket.assigns.current_scope, socket.assigns.task, file, line) do
      %{rows: rows} = hunk -> %{hunk | rows: Enum.map(rows, &focus(&1, finding))}
      nil -> nil
    end
  end

  defp hunk(_socket, %Finding{}), do: nil

  defp focus(%{kind: :line, new_line: new_line} = row, %Finding{line: first, end_line: last})
       when is_integer(new_line) and is_integer(first) and is_integer(last) do
    if new_line in first..last//1, do: Map.put(row, :focus?, true), else: row
  end

  defp focus(row, %Finding{}), do: row

  # Read off the row alone: a text file's opening was read into the finding when it was attached.
  defp filed(socket, %Finding{key: key, evidence: evidence}) do
    task = socket.assigns.task

    for {piece, index} <- Enum.with_index(evidence), piece.kind != :code do
      url = if is_binary(piece.path), do: ~p"/tasks/#{task.id}/findings/#{key}/evidence/#{index}"
      %{index: index, evidence: piece, kind: kind(piece), url: url}
    end
  end

  defp kind(%FindingEvidence{text: text}) when is_binary(text), do: :inline

  defp kind(%FindingEvidence{path: path}) do
    cond do
      FindingEvidence.picture?(path) -> :screenshot
      String.downcase(Path.extname(path)) == ".pdf" -> :pdf
      true -> :file
    end
  end

  defp names(socket, %Finding{notes: notes}) do
    case for(%{by_id: id} <- notes, is_binary(id), uniq: true, do: id) do
      [] ->
        %{}

      ids ->
        socket.assigns.current_scope |> Users.list_users_by_ids(ids) |> Map.new(&{&1.id, &1.name || &1.login})
    end
  end

  defp suppressor(%Finding{suppressed_by_id: rule_id} = finding) when is_binary(rule_id) do
    if Finding.suppressed?(finding) do
      {:ok, rules} = Learnings.list_learnings(ids: [rule_id])
      List.first(rules)
    end
  end

  defp suppressor(%Finding{}), do: nil

  # The next one down that still needs a call, or else the first from the top.
  defp next_undecided(findings, finding) do
    {above, [_ruled | below]} = Enum.split_while(findings, &(&1.key != finding.key))
    Enum.find(below ++ above, &Finding.undecided?/1)
  end

  # The second click of a double click lands on the finding just moved to, which nobody has read yet.
  defp double_click?({key, at}, key), do: System.monotonic_time(:millisecond) - at < @double_click_ms
  defp double_click?(_advanced_to, _key), do: false

  defp item("diff"), do: :diff
  defp item("screens"), do: :screens
  defp item("demo"), do: :demo
  defp item("browser"), do: :browser
  defp item(_findings), do: :findings

  defp decision("fix"), do: :fix
  defp decision("skip"), do: :skip

  defp message_for(:stage_running), do: "Something is still running on this task."
  defp message_for(:no_stage_run), do: "Review has no run to ask yet."
  defp message_for(:chat_unavailable), do: "The Review lead has no conversation to ask yet."
  defp message_for({:invalid_stage, stage}), do: "This task is at #{Task.stage_label(stage)}, not Review."
  defp message_for(:findings_undecided), do: "Some findings have no ruling yet. Rule on every one first."
  defp message_for(:nothing_to_start), do: "There is nothing left to start: the review is finished."
  defp message_for(:dispatch_disabled), do: "Dispatch is off, so the Review lead was not resumed."
  defp message_for(:review_finished), do: "The review is finished, so its rulings are settled."
  defp message_for(:ci_not_passed), do: "CI has not passed on the fix commit, so the review cannot finish yet."
end
