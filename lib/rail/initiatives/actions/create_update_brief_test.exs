defmodule Rail.Initiatives.Actions.CreateUpdateBriefTest do
  use Rail.DataCase, async: true

  alias Rail.Initiatives
  alias Rail.Initiatives.Schemas.InitiativeComment
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects
  alias Rail.Users

  @done %{id: "done", name: "Done", state: :done}
  @in_progress %{id: "in_progress", name: "In Progress", state: :in_progress}
  @in_review %{id: "in_review", name: "In Review", state: :in_review}
  @canceled %{id: "canceled", name: "Canceled", state: :canceled}
  @todo %{id: "todo", name: "Todo", state: :todo}

  setup do
    key = "CUB#{System.unique_integer([:positive])}"

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Briefs",
        github_repo: "example/#{key}",
        github_installation_id: 1,
        key: key,
        default_branch: "main",
        clone_path: "/tmp/#{key}"
      })

    {:ok, paulo} =
      Users.register_oauth_user(%{
        github_id: "gh_#{key}_paulo",
        login: "paulo",
        name: "Paulo",
        email: "#{key}@example.com"
      })

    {:ok, paulo} = Users.update_user(system_scope(), paulo, %{project_ids: [project.id]})

    {:ok, sam} =
      Users.register_oauth_user(%{github_id: "gh_#{key}_sam", login: "sam-o", name: nil, email: "#{key}-sam@example.com"})

    {:ok, initiative} =
      Initiatives.create_initiative(system_scope(), project, %{name: "Credo exclusions", expected_on: ~D[2026-12-12]})

    tickets =
      for {title, owner} <- [{"Two API actions", paulo}, {"The Banks sync job", paulo}, {"Bank Reconciliation", nil}] do
        {:ok, issue} =
          Issues.create_issue(system_scope(), project, %{title: title, owner_user_id: owner && owner.id})

        {:ok, issue} = Issues.set_issue_initiative(system_scope(), issue, initiative.id)
        issue
      end

    {:ok, review} = Issues.create_issue(system_scope(), project, %{title: "Payroll export", owner_user_id: sam.id})
    {:ok, review} = Issues.set_issue_initiative(system_scope(), review, initiative.id)

    %{project: project, key: key, initiative: initiative, tickets: tickets, review: review, user: paulo}
  end

  test "posts a brief in the example's format, by the scope's user, and broadcasts it", %{
    key: key,
    initiative: %{id: initiative_id, project_id: project_id} = initiative,
    tickets: [two_api, banks, _reconciliation],
    review: review,
    user: %{id: user_id} = user
  } do
    {:ok, _issue} = Issues.set_issue_status(system_scope(), two_api, @done)
    {:ok, _issue} = Issues.set_issue_status(system_scope(), banks, @in_progress)
    {:ok, _issue} = Issues.set_issue_status(system_scope(), review, @in_review)
    Phoenix.PubSub.subscribe(Rail.PubSub, "initiatives")
    stub(DateTime, :utc_now, fn -> ~U[2026-11-23 09:14:00.000000Z] end)

    expected = """
    **Credo exclusions**: update for Nov 23, 2026

    **25% done**: 1 of 4 tickets. Expected Dec 12, 2026, 19 days left.

    **Done since the last update (1)**
    - #{key}-1 Two API actions · Paulo

    **In progress (2)**
    - #{key}-2 The Banks sync job · Paulo
    - #{key}-4 Payroll export · sam-o

    **Not started (1)**
    - #{key}-3 Bank Reconciliation

    #{RailWeb.Endpoint.url()}/initiatives/#{initiative_id}\
    """

    assert {:ok, %InitiativeComment{initiative_id: ^initiative_id, author_user_id: ^user_id, body: ^expected}} =
             Initiatives.create_update_brief(user_scope(user: user), initiative)

    assert_receive {:initiatives_changed, ^project_id}

    assert %InitiativeComment{inserted_at: ~U[2026-11-23 09:14:00.000000Z]} =
             Repo.get_by!(InitiativeComment, initiative_id: initiative_id)
  end

  test "the first brief lists every Done ticket, and a second only those Done since, not one still Done", %{
    key: key,
    initiative: initiative,
    tickets: [two_api, banks, reconciliation]
  } do
    {:ok, _issue} = Issues.set_issue_status(system_scope(), two_api, @done)
    {:ok, _issue} = Issues.set_issue_status(system_scope(), banks, @done)

    assert {:ok, %InitiativeComment{body: first}} = Initiatives.create_update_brief(system_scope(), initiative)

    assert first =~
             "**Done since the last update (2)**\n- #{key}-1 Two API actions · Paulo\n- #{key}-2 The Banks sync job"

    {:ok, _issue} = Issues.set_issue_status(system_scope(), reconciliation, @done)

    assert {:ok, %InitiativeComment{author_user_id: nil, body: second}} =
             Initiatives.create_update_brief(system_scope(), initiative)

    assert second =~ "**Done since the last update (1)**\n- #{key}-3 Bank Reconciliation\n\n"
    refute second =~ "- #{key}-1 Two API actions"
    assert second =~ "**75% done**: 3 of 4 tickets."
  end

  test "a brief posted again at once lists nothing as Done since, and a reopened ticket only once Done again", %{
    key: key,
    initiative: initiative,
    tickets: [two_api | _rest]
  } do
    {:ok, _issue} = Issues.set_issue_status(system_scope(), two_api, @done)
    {:ok, _first} = Initiatives.create_update_brief(system_scope(), initiative)

    assert {:ok, %InitiativeComment{body: again}} = Initiatives.create_update_brief(system_scope(), initiative)
    assert again =~ "**Done since the last update (0)**\n\n**In progress"

    {:ok, _issue} = Issues.set_issue_status(system_scope(), two_api, @todo)
    {:ok, _issue} = Issues.set_issue_status(system_scope(), two_api, @done)

    assert {:ok, %InitiativeComment{body: reopened}} = Initiatives.create_update_brief(system_scope(), initiative)
    assert reopened =~ "**Done since the last update (1)**\n- #{key}-1 Two API actions"
  end

  test "a ticket in Done with no time it finished is never listed as done since", %{
    initiative: initiative,
    tickets: [two_api, banks, _reconciliation]
  } do
    {:ok, _issue} = Issues.set_issue_status(system_scope(), two_api, @done)
    {:ok, _first} = Initiatives.create_update_brief(system_scope(), initiative)
    Repo.update_all(from(i in Issue, where: i.id == ^banks.id), set: [state: :done])

    assert {:ok, %InitiativeComment{body: body}} = Initiatives.create_update_brief(system_scope(), initiative)
    assert body =~ "**Done since the last update (0)**"
    assert body =~ "**50% done**: 2 of 4 tickets."
  end

  test "a canceled ticket is in no section and out of the count, and no expected date says none", %{
    key: key,
    initiative: initiative,
    tickets: [_two_api, banks, _reconciliation]
  } do
    {:ok, _issue} = Issues.set_issue_status(system_scope(), banks, @canceled)
    {:ok, initiative} = Initiatives.update_initiative(system_scope(), initiative, %{expected_on: nil})

    assert {:ok, %InitiativeComment{body: body}} = Initiatives.create_update_brief(system_scope(), initiative)

    assert body =~ "**0% done**: 0 of 3 tickets.\n\n"
    refute body =~ "#{key}-2"
    refute body =~ "Expected"
  end

  test "an initiative deleted meanwhile, or in a project the scope cannot open, posts nothing", %{
    project: project,
    initiative: initiative
  } do
    assert {:error, :not_found} = Initiatives.create_update_brief(temp_user_scope(project_ids: []), initiative)
    refute_received {:initiatives_changed, _project_id}

    :ok = Initiatives.delete_initiative(system_scope(), initiative)
    Phoenix.PubSub.subscribe(Rail.PubSub, "initiatives")

    assert {:error, :not_found} = Initiatives.create_update_brief(user_scope(project_ids: [project.id]), initiative)
    refute_received {:initiatives_changed, _project_id}
  end
end
