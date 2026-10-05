defmodule RailWeb.LearningsLive do
  @moduledoc false
  use RailWeb, :live_view

  alias Rail.Learnings
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Schemas.LearningProposal
  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Scope
  alias RailWeb.Components.LearningsChannelPicker

  @statuses [:review, :active, :provisional, :retired]
  @double_click_ms 400

  @errors %{
    already_decided: "Someone already decided this proposal.",
    not_found: "Someone already decided this proposal.",
    retired: "This rule was retired, so it cannot be made active again.",
    linear_team_not_found: "This project has no Linear team to open the issue in."
  }

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Rail.PubSub, "learnings")
      Phoenix.PubSub.subscribe(Rail.PubSub, "projects")
    end

    project =
      case socket.assigns.current_project_id && Projects.get_project(socket.assigns.current_project_id) do
        {:ok, project} -> project
        _all_projects -> nil
      end

    # Only the connected mount asks Slack, so a page load costs one call; the dead render shows the id.
    channel_name =
      cond do
        is_nil(project) -> nil
        connected?(socket) -> LearningsChannelPicker.channel_name(project)
        true -> project.learnings_channel_external_id
      end

    socket =
      socket
      |> assign(:page_title, "Learnings")
      |> assign(:current_section, :learnings)
      |> assign(:project, project)
      |> assign(:channel_name, channel_name)
      |> assign(:show_digest_picker, is_struct(project, Project) and Scope.admin?(socket.assigns.current_scope))
      |> assign(:open_menu, nil)
      |> assign(:form, nil)
      |> assign(:form_target, nil)
      |> assign(:form_project_id, nil)
      |> assign(:error, nil)
      |> assign(:show_all_suppressed, false)
      |> assign(:query_embedding, nil)
      |> assign(:decided, nil)

    {:ok, socket}
  end

  # The segment, search, filters and open item are all in the URL, so any of
  # them can be linked to and survives a reload; the project is the switcher's.
  def handle_params(params, _uri, socket) do
    selected =
      case {socket.assigns.live_action, params["id"]} do
        {:rule, id} -> {:rule, id}
        {:proposal, id} -> {:proposal, id}
        {:index, nil} -> nil
      end

    socket =
      socket
      |> assign(:status_param, Enum.find(@statuses, &(Atom.to_string(&1) == params["status"])))
      |> assign(:query, String.trim(params["q"] || ""))
      |> assign(:kind, Enum.find(Learning.kinds(), &(Atom.to_string(&1) == params["kind"])))
      |> assign(:role, Enum.find(Learning.roles(), &(Atom.to_string(&1) == params["role"])))
      |> assign(:auto, params["auto"] == "true")
      |> assign(:week, params["week"] == "true")
      |> assign(:selected, selected)
      |> assign(:error, nil)
      |> assign(:open_menu, nil)
      |> assign(:show_all_suppressed, false)
      |> load()

    {:noreply, open_override_as_rule(socket)}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_section={@current_section}
      current_scope={@current_scope}
      is_rail_extended={@is_rail_extended}
      attention_count={@attention_count}
      triage_count={@triage_count}
      current_project_id={@current_project_id}
      projects={@projects}
      theme={@theme}
      show_project_switcher={@show_project_switcher}
      lost_backends={@lost_backends}
    >
      <div id="learnings-page" data-qa="learnings-page" class="-m-6 h-[calc(100%+3rem)] flex min-h-0">
        <.learnings_queue
          status={@status}
          counts={@counts}
          learnings={@learnings}
          proposals={@proposals}
          query={@query}
          kind={@kind}
          role={@role}
          auto={@auto}
          week={@week}
          open_menu={@open_menu}
          selected_id={@selected_id}
          params={@params}
          search_unavailable={@search_unavailable}
          project_name={@project && @project.name}
          show_projects={is_nil(@project)}
          digest={@digest}
        >
          <:digest_picker :if={@show_digest_picker}>
            <.live_component
              module={LearningsChannelPicker}
              id="learnings-digest-picker"
              variant={:footer}
              current_scope={@current_scope}
              project={@project}
              channel_name={@channel_name}
              permalink={@digest.permalink}
            />
          </:digest_picker>
        </.learnings_queue>

        <.learning_detail
          :if={@learning}
          learning={@learning}
          stats={@stats}
          show_all_suppressed={@show_all_suppressed}
          error={@error}
        />

        <.learning_proposal_detail :if={@proposal} proposal={@proposal} error={@error} />
      </div>
    </Layouts.app>

    <.learning_form_modal
      :if={@form}
      changeset={@form}
      title={form_title(@form_target)}
      projects={@projects}
      project_id={@form_project_id}
      show_project_picker={@form_target == :new and is_nil(@project)}
    />
    """
  end

  def handle_event("status", %{"status" => status}, socket) do
    {:noreply, push_patch(socket, to: list_path(socket.assigns, status: status))}
  end

  # Proposals are not searched, so a search typed while reviewing looks through the active rules.
  def handle_event("search", %{"q" => query}, socket) do
    status = if socket.assigns.status == :review and String.trim(query) != "", do: :active, else: socket.assigns.status
    {:noreply, push_patch(socket, to: list_path(socket.assigns, q: query, status: status))}
  end

  def handle_event("filter_kind", %{"kind" => kind}, socket) do
    {:noreply, push_patch(socket, to: list_path(socket.assigns, kind: kind))}
  end

  def handle_event("filter_role", %{"role" => role}, socket) do
    {:noreply, push_patch(socket, to: list_path(socket.assigns, role: role))}
  end

  def handle_event("toggle_auto", _params, socket) do
    {:noreply, push_patch(socket, to: list_path(socket.assigns, auto: not socket.assigns.auto))}
  end

  def handle_event("toggle_week", _params, socket) do
    {:noreply, push_patch(socket, to: list_path(socket.assigns, week: not socket.assigns.week))}
  end

  def handle_event("toggle_menu", %{"menu" => menu}, socket) do
    menu = if menu == "kind", do: :kind, else: :role
    {:noreply, assign(socket, :open_menu, if(socket.assigns.open_menu == menu, do: nil, else: menu))}
  end

  def handle_event("close_menu", _params, socket), do: {:noreply, assign(socket, :open_menu, nil)}

  def handle_event("new_learning", _params, socket) do
    project_id =
      (socket.assigns.project && socket.assigns.project.id) ||
        Enum.find_value(socket.assigns.projects, &(&1.active && &1.id))

    socket =
      socket
      |> assign(:form, Learning.changeset(%Learning{kind: :convention}, %{}))
      |> assign(:form_target, :new)
      |> assign(:form_project_id, project_id)

    {:noreply, socket}
  end

  def handle_event("edit_learning", _params, socket) do
    learning = socket.assigns.learning || socket.assigns.proposal.learning

    socket =
      socket
      |> assign(:form, Learning.changeset(learning, %{}))
      |> assign(:form_target, learning)

    {:noreply, socket}
  end

  def handle_event("validate_learning", %{"learning" => params}, socket) do
    base = if socket.assigns.form_target == :new, do: %Learning{}, else: socket.assigns.form_target

    socket =
      socket
      |> assign(:form, base |> Learning.changeset(attrs(params)) |> Map.put(:action, :validate))
      |> assign(:form_project_id, params["project_id"] || socket.assigns.form_project_id)

    {:noreply, socket}
  end

  def handle_event("save_learning", %{"learning" => params}, socket) do
    scope = socket.assigns.current_scope

    result =
      case socket.assigns.form_target do
        # Only a project the person may see, whatever the form sent.
        :new ->
          project_id = params["project_id"] || socket.assigns.form_project_id

          case Enum.find(socket.assigns.projects, &(&1.id == project_id)) do
            %Project{} = project -> Learnings.create_learning(scope, project, attrs(params))
            nil -> {:error, Ecto.Changeset.add_error(socket.assigns.form, :project_id, "is not one of your projects")}
          end

        %Learning{} = learning ->
          Learnings.update_learning(scope, learning, attrs(params))
      end

    case result do
      {:ok, saved} ->
        socket = socket |> assign(:form, nil) |> assign(:form_target, nil)
        {:noreply, saved_to(socket, socket.assigns.proposal, saved)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, changeset)}
    end
  end

  def handle_event("close_form", _params, socket) do
    socket = socket |> assign(:form, nil) |> assign(:form_target, nil)
    {:noreply, socket}
  end

  def handle_event("retire_learning", _params, socket) do
    {:ok, _retired} = Learnings.retire_learning(socket.assigns.current_scope, socket.assigns.learning)
    {:noreply, load(socket)}
  end

  # Each decision names its proposal, so a second click lands on the one already
  # decided, or is dropped when it lands on the proposal the queue opened after it.
  def handle_event("keep_rule", %{"id" => id}, socket) do
    with {:ok, proposal} <- visible_proposal(socket, id),
         {:ok, _kept} <- Learnings.reject_learning_proposal(socket.assigns.current_scope, proposal) do
      {:noreply, load(socket)}
    else
      {:error, reason} -> refused(socket, reason)
    end
  end

  def handle_event("keep_rule", _no_override, socket), do: {:noreply, load(socket)}

  def handle_event("approve_proposal", %{"id" => id}, socket) do
    decide(socket, id, &Learnings.approve_learning_proposal(socket.assigns.current_scope, &1))
  end

  def handle_event("reject_proposal", %{"id" => id}, socket) do
    decide(socket, id, &Learnings.reject_learning_proposal(socket.assigns.current_scope, &1))
  end

  def handle_event("show_all_suppressed", _params, socket) do
    {:noreply, assign(socket, :show_all_suppressed, true)}
  end

  # Every writer broadcasts, so a rule another tab or the curator changed shows here
  # too; another project's change is only news under All projects.
  def handle_info({:learnings_changed, project_id}, %{assigns: %{project: project}} = socket) do
    if is_nil(project) or project.id == project_id, do: {:noreply, load(socket)}, else: {:noreply, socket}
  end

  # A channel picked here or in another tab is named again; anything else about the project costs no Slack call.
  def handle_info({:project_changed, id}, %{assigns: %{project: %Project{id: id}}} = socket) do
    {:ok, project} = Projects.get_project(id)
    channel_name = LearningsChannelPicker.channel_name(project, socket.assigns.project, socket.assigns.channel_name)

    socket =
      socket
      |> assign(:project, project)
      |> assign(:channel_name, channel_name)
      |> assign(:digest, digest(project, channel_name))

    {:noreply, socket}
  end

  # The navigation hook and the issue dialog broadcast things this page has no use for.
  def handle_info(_message, socket), do: {:noreply, socket}

  # A decided proposal leaves the queue, so the next one is opened in its place.
  defp decide(socket, id, action) do
    with false <- double_click?(socket.assigns.decided, id),
         {:ok, proposal} <- visible_proposal(socket, id),
         {:ok, _decided} <- action.(proposal) do
      socket =
        socket
        |> assign(:decided, {id, System.monotonic_time(:millisecond)})
        |> push_patch(to: list_path(socket.assigns, []))

      {:noreply, socket}
    else
      true -> {:noreply, socket}
      {:error, reason} -> refused(socket, reason)
    end
  end

  # A crafted id for another project's proposal is told what a missing one is.
  defp visible_proposal(socket, id) do
    with {:ok, proposal} <- Learnings.get_learning_proposal(id),
         true <- Scope.can_access_project?(socket.assigns.current_scope, proposal.project_id) do
      {:ok, proposal}
    else
      _missing_or_hidden -> {:error, :not_found}
    end
  end

  defp double_click?({decided_id, at}, id) when decided_id != id,
    do: System.monotonic_time(:millisecond) - at < @double_click_ms

  defp double_click?(_decided, _id), do: false

  defp refused(socket, reason) do
    socket = socket |> load() |> assign(:error, error_message(reason))
    {:noreply, socket}
  end

  # A proposal's draft is edited on the way to deciding it, so saving goes back to the proposal.
  defp saved_to(socket, %LearningProposal{id: proposal_id, learning_id: id}, %Learning{id: id}) do
    push_patch(socket, to: ~p"/learnings/proposals/#{proposal_id}?#{socket.assigns.params}")
  end

  defp saved_to(socket, _proposal, %Learning{id: id, status: status}) do
    params = Keyword.put(socket.assigns.params, :status, status)
    push_patch(socket, to: ~p"/learnings/#{id}?#{params}")
  end

  defp load(socket) do
    assigns = socket.assigns
    project_id = assigns.project_filter
    detail = detail(assigns.selected, assigns.current_scope)
    status = assigns.status_param || status_of(detail)
    query_embedding = query_embedding(assigns, status)
    {learnings, proposals, unavailable} = list(assigns, project_id, status, query_embedding)
    detail = detail || first(learnings, proposals, assigns.current_scope)

    socket
    |> assign(:query_embedding, query_embedding)
    |> assign(:status, status)
    |> assign(:counts, Learnings.count_learnings(project_id: project_id))
    |> assign(:learnings, learnings)
    |> assign(:proposals, proposals)
    |> assign(:search_unavailable, unavailable)
    |> assign(:digest, digest(assigns.project, assigns.channel_name))
    |> assign_detail(detail)
    |> assign_params()
  end

  # A reload with the same search reuses its embedding, so a broadcast costs no Vertex request.
  defp query_embedding(%{query: ""}, _status), do: nil
  defp query_embedding(_assigns, :review), do: nil
  defp query_embedding(%{query: query, query_embedding: {query, {:ok, _vector}} = cached}, _status), do: cached
  defp query_embedding(%{query: query}, _status), do: {query, Learnings.embed_query(query)}

  defp list(assigns, project_id, :review, _query_embedding) do
    {[], Learnings.list_learning_proposals(project_id: project_id, kind: assigns.kind), false}
  end

  defp list(_assigns, _project_id, _status, {_query, {:error, _unembeddable}}), do: {[], [], true}

  defp list(assigns, project_id, status, query_embedding) do
    {:ok, learnings} =
      Learnings.list_learnings(
        project_id: project_id,
        status: status,
        kind: assigns.kind,
        role: assigns.role,
        auto: assigns.auto,
        activated_since: if(assigns.week, do: DateTime.shift(DateTime.utc_now(), week: -1)),
        query: assigns.query,
        embedding: with({_query, {:ok, vector}} <- query_embedding, do: vector)
      )

    {learnings, [], false}
  end

  # A rule or proposal in a project the person cannot see opens as one that is not there.
  defp detail({:rule, id}, scope) do
    with {:ok, learning} <- Learnings.get_learning(id),
         true <- Scope.can_access_project?(scope, learning.project_id) do
      {:rule, learning}
    else
      _missing_or_hidden -> nil
    end
  end

  defp detail({:proposal, id}, scope) do
    with {:ok, proposal} <- Learnings.get_learning_proposal(id),
         true <- Scope.can_access_project?(scope, proposal.project_id) do
      {:proposal, proposal}
    else
      _missing_or_hidden -> nil
    end
  end

  defp detail(nil, _scope), do: nil

  # A link to a rule or proposal with no segment named opens the segment it is in.
  defp status_of({:rule, %Learning{status: :proposed}}), do: :review
  defp status_of({:rule, %Learning{status: status}}), do: status
  defp status_of(_proposal_or_nothing), do: :review

  defp first([learning | _rest], _proposals, _scope), do: {:rule, learning}

  defp first([], [%LearningProposal{action: :override, learning_id: id} | _rest], scope), do: detail({:rule, id}, scope)

  defp first([], [%LearningProposal{id: id} | _rest], scope), do: detail({:proposal, id}, scope)
  defp first([], [], _scope), do: nil

  defp assign_detail(socket, {:rule, %Learning{} = learning}) do
    socket
    |> assign(:learning, learning)
    |> assign(:stats, Learnings.get_learning_stats(learning))
    |> assign(:proposal, nil)
    |> assign(:selected_id, learning.id)
  end

  defp assign_detail(socket, {:proposal, %LearningProposal{} = proposal}) do
    socket
    |> assign(:learning, nil)
    |> assign(:stats, nil)
    |> assign(:proposal, proposal)
    |> assign(:selected_id, proposal.id)
  end

  defp assign_detail(socket, nil) do
    socket
    |> assign(:learning, nil)
    |> assign(:stats, nil)
    |> assign(:proposal, nil)
    |> assign(:selected_id, nil)
  end

  # An override is decided on the rule it flags, so its own URL opens that rule.
  defp open_override_as_rule(%{assigns: %{proposal: %LearningProposal{action: :override} = proposal}} = socket) do
    push_patch(socket, to: ~p"/learnings/#{proposal.learning_id}?#{socket.assigns.params}")
  end

  defp open_override_as_rule(socket), do: socket

  defp assign_params(socket) do
    assigns = socket.assigns

    params =
      Enum.reject(
        [
          status: assigns.status,
          q: assigns.query,
          kind: assigns.kind,
          role: assigns.role,
          auto: assigns.auto,
          week: assigns.week
        ],
        fn {_key, value} -> value in [nil, "", false] end
      )

    assign(socket, :params, params)
  end

  defp list_path(assigns, changes) do
    params =
      assigns.params
      |> Keyword.merge(changes)
      |> Enum.reject(fn {_key, value} -> value in [nil, "", false] end)

    ~p"/learnings?#{params}"
  end

  defp digest(nil, _channel_name), do: nil

  # The latest digest stays linked after the channel changes, even though it was posted in the old one.
  defp digest(%Project{} = project, channel_name) do
    permalink =
      case Learnings.get_latest_curator_pass(project) do
        {:ok, pass} -> pass.digest_permalink
        {:error, :not_found} -> nil
      end

    %{channel: channel_name, permalink: permalink}
  end

  defp attrs(params) do
    %{
      "rule" => params["rule"],
      "why" => params["why"],
      "kind" => params["kind"],
      "roles" => Enum.reject(params["roles"] || [], &(&1 == "")),
      "path_glob" => params["path_glob"],
      "pinned" => params["pinned"]
    }
  end

  defp form_title(:new), do: "Add rule"
  defp form_title(%Learning{status: :proposed}), do: "Edit the proposed rule"
  defp form_title(%Learning{}), do: "Edit rule"

  defp error_message(reason), do: Map.get_lazy(@errors, reason, fn -> "That did not work: #{inspect(reason)}" end)
end
