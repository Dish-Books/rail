defmodule Rail.Issues.Clients.LinearTest do
  use Rail.DataCase, async: true

  alias Rail.Issues.Clients.Linear
  alias RailTest.Mocks.Linear, as: LinearMock

  test "viewer/2 returns viewer details on success" do
    LinearMock.mock_viewer_success(id: "lin_usr_456", name: "Alice Dev", email: "alice@example.com")

    assert {:ok, %{id: "lin_usr_456", name: "Alice Dev", email: "alice@example.com"}} =
             Linear.viewer("token_123")
  end

  test "viewer/2 returns error on 401" do
    LinearMock.mock_viewer_error(401)

    assert {:error, {:linear_api_error, 401, %{"errors" => [%{"message" => "Not authenticated"}]}}} =
             Linear.viewer("invalid_token")
  end

  test "issues/4 retrieves issues for team without updated_since" do
    nodes = [
      %{
        "id" => "lin_iss_1",
        "identifier" => "ENG-1",
        "title" => "First",
        "description" => "First desc",
        "state" => %{"id" => "st_1", "name" => "Triage", "type" => "triage"},
        "branchName" => "branch-1",
        "url" => "https://linear.app/issue/ENG-1",
        "createdAt" => "2026-09-01T10:00:00.000Z",
        "updatedAt" => "2026-09-01T11:00:00.000Z"
      }
    ]

    LinearMock.mock_issues_success(nodes)

    assert {:ok,
            [
              %{
                id: "lin_iss_1",
                identifier: "ENG-1",
                title: "First",
                description: "First desc",
                state: %{id: "st_1", name: "Triage", type: "triage"},
                branch_name: "branch-1",
                url: "https://linear.app/issue/ENG-1",
                created_at: "2026-09-01T10:00:00.000Z",
                updated_at: "2026-09-01T11:00:00.000Z"
              }
            ]} = Linear.issues("token_123", "team_1")
  end

  test "issues/4 retrieves issues for team with updated_since DateTime" do
    nodes = [
      %{
        "id" => "lin_iss_2",
        "identifier" => "ENG-2",
        "title" => "Second",
        "description" => "Second desc",
        "state" => %{"id" => "st_2", "name" => "In Progress", "type" => "started"},
        "branchName" => "branch-2",
        "url" => "https://linear.app/issue/ENG-2",
        "createdAt" => "2026-09-02T10:00:00.000Z",
        "updatedAt" => "2026-09-02T11:00:00.000Z"
      }
    ]

    LinearMock.mock_issues_success(nodes)

    since = ~U[2026-09-02 00:00:00.000000Z]

    assert {:ok,
            [
              %{
                id: "lin_iss_2",
                identifier: "ENG-2",
                title: "Second",
                state: %{type: "started"}
              }
            ]} = Linear.issues("token_123", "team_1", since)
  end

  test "issues/4 retrieves issues for team with updated_since ISO string" do
    LinearMock.mock_issues_success([])

    assert {:ok, []} = Linear.issues("token_123", "team_1", "2026-09-01T00:00:00Z")
  end

  test "issue/3 retrieves issue by id" do
    issue_data = %{
      "id" => "lin_iss_1",
      "identifier" => "ENG-1",
      "title" => "Target issue",
      "description" => "Issue details",
      "state" => %{"id" => "st_1", "name" => "Triage", "type" => "triage"},
      "branchName" => "branch-1",
      "url" => "https://linear.app/issue/ENG-1",
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-01T11:00:00.000Z"
    }

    LinearMock.mock_issue_success(issue_data)

    assert {:ok,
            %{
              id: "lin_iss_1",
              identifier: "ENG-1",
              title: "Target issue"
            }} = Linear.issue("token_123", "lin_iss_1")
  end

  test "issue/3 returns not_found when issue is nil" do
    LinearMock.mock_issue_not_found()

    assert {:error, :not_found} = Linear.issue("token_123", "nonexistent")
  end

  test "create_issue/3 creates issue successfully" do
    created_issue = %{
      "id" => "lin_new_1",
      "identifier" => "ENG-50",
      "title" => "New Bug",
      "description" => "Bug details",
      "state" => %{"id" => "st_1", "name" => "Triage", "type" => "triage"},
      "branchName" => "eng-50-branch",
      "url" => "https://linear.app/issue/ENG-50",
      "createdAt" => "2026-09-05T10:00:00.000Z",
      "updatedAt" => "2026-09-05T10:00:00.000Z"
    }

    LinearMock.mock_create_issue_success(created_issue)

    assert {:ok,
            %{
              id: "lin_new_1",
              identifier: "ENG-50",
              title: "New Bug"
            }} =
             Linear.create_issue("token_123", %{
               team_id: "team_1",
               title: "New Bug",
               description: "Bug details",
               state_id: "st_1"
             })
  end

  test "create_issue/3 returns error when mutation fails" do
    LinearMock.mock_mutation_failure("issueCreate")

    assert {:error, {:linear_mutation_failed, "issueCreate"}} =
             Linear.create_issue("token_123", %{team_id: "team_1", title: "Fail"})
  end

  test "update_issue/4 updates issue successfully" do
    updated_issue = %{
      "id" => "lin_iss_1",
      "identifier" => "ENG-1",
      "title" => "Updated Title",
      "description" => "Updated Desc",
      "state" => %{"id" => "st_2", "name" => "In Progress", "type" => "started"},
      "branchName" => "eng-1-branch",
      "url" => "https://linear.app/issue/ENG-1",
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-05T12:00:00.000Z"
    }

    LinearMock.mock_update_issue_success(updated_issue)

    assert {:ok,
            %{
              id: "lin_iss_1",
              title: "Updated Title",
              state: %{type: "started"}
            }} =
             Linear.update_issue("token_123", "lin_iss_1", %{
               title: "Updated Title",
               description: "Updated Desc",
               state_id: "st_2"
             })
  end

  test "update_issue/4 returns error when mutation fails" do
    LinearMock.mock_mutation_failure("issueUpdate")

    assert {:error, {:linear_mutation_failed, "issueUpdate"}} =
             Linear.update_issue("token_123", "lin_iss_1", %{title: "Fail"})
  end

  test "workflow_states/3 returns team states" do
    states = [
      %{"id" => "st_1", "name" => "Triage", "type" => "triage"},
      %{"id" => "st_2", "name" => "In Progress", "type" => "started"}
    ]

    LinearMock.mock_workflow_states_success(states)

    assert {:ok,
            [
              %{id: "st_1", name: "Triage", type: "triage"},
              %{id: "st_2", name: "In Progress", type: "started"}
            ]} = Linear.workflow_states("token_123", "team_1")
  end

  test "workflow_states/3 returns not_found when team is nil" do
    Req.Test.expect(Rail.Linear, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"data" => %{"team" => nil}}))
    end)

    assert {:error, :not_found} = Linear.workflow_states("token_123", "nonexistent_team")
  end

  test "file_upload/6 performs two-step upload" do
    LinearMock.mock_file_upload_success(
      upload_url: "https://api.linear.app/upload/asset_999",
      asset_url: "https://uploads.linear.app/asset_999/diagram.png",
      asset_id: "asset_999"
    )

    data = "PNG_BINARY_DATA"

    assert {:ok,
            %{
              asset_id: "asset_999",
              asset_url: "https://uploads.linear.app/asset_999/diagram.png"
            }} = Linear.file_upload("token_123", "diagram.png", "image/png", byte_size(data), data)
  end

  test "file_upload/6 returns error when fileUpload mutation fails" do
    LinearMock.mock_mutation_failure("fileUpload")

    data = "PNG_DATA"

    assert {:error, {:linear_mutation_failed, "fileUpload"}} =
             Linear.file_upload("token_123", "file.png", "image/png", byte_size(data), data)
  end

  test "file_upload/6 returns error when PUT fails" do
    LinearMock.mock_file_upload_success(put_status: 500)

    data = "PNG_DATA"

    assert {:error, {:linear_upload_error, 500, _body}} =
             Linear.file_upload("token_123", "file.png", "image/png", byte_size(data), data)
  end

  test "create_comment/4 posts comment successfully" do
    comment = %{
      "id" => "comment_1",
      "body" => "Hello world",
      "createdAt" => "2026-09-05T12:00:00.000Z"
    }

    LinearMock.mock_create_comment_success(comment)

    assert {:ok, %{id: "comment_1", body: "Hello world"}} =
             Linear.create_comment("token_123", "lin_iss_1", "Hello world")
  end

  test "create_comment/4 returns error when mutation fails" do
    LinearMock.mock_mutation_failure("commentCreate")

    assert {:error, {:linear_mutation_failed, "commentCreate"}} =
             Linear.create_comment("token_123", "lin_iss_1", "Hello world")
  end

  test "attachment_create/3 creates attachment successfully" do
    attachment = %{
      "id" => "attach_1",
      "url" => "https://example.com/asset.png",
      "title" => "Asset Preview"
    }

    LinearMock.mock_attachment_create_success(attachment)

    assert {:ok,
            %{
              id: "attach_1",
              url: "https://example.com/asset.png",
              title: "Asset Preview"
            }} =
             Linear.attachment_create("token_123", %{
               issue_id: "lin_iss_1",
               url: "https://example.com/asset.png",
               title: "Asset Preview"
             })
  end

  test "attachment_create/3 returns error when mutation fails" do
    LinearMock.mock_mutation_failure("attachmentCreate")

    assert {:error, {:linear_mutation_failed, "attachmentCreate"}} =
             Linear.attachment_create("token_123", %{issue_id: "lin_iss_1"})
  end

  test "handles GraphQL error with status 200" do
    LinearMock.mock_graphql_error([%{"message" => "Field does not exist"}])

    assert {:error, {:linear_graphql_error, [%{"message" => "Field does not exist"}]}} =
             Linear.issue("token_123", "lin_iss_1")
  end

  test "handles API error with status 500" do
    LinearMock.mock_api_error(500, %{"error" => "Internal Server Error"})

    assert {:error, {:linear_api_error, 500, %{"error" => "Internal Server Error"}}} =
             Linear.issue("token_123", "lin_iss_1")
  end

  test "handles network error in execute_query" do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.transport_error(conn, :timeout)
    end)

    assert {:error, %Req.TransportError{reason: :timeout}} =
             Linear.viewer("token_123")
  end

  test "handles network error during binary PUT upload" do
    LinearMock.mock_file_upload_success(
      upload_url: "https://api.linear.app/upload/asset_timeout",
      asset_url: "https://uploads.linear.app/asset_timeout/file.png",
      put_error: :econnrefused
    )

    assert {:error, %Req.TransportError{reason: :econnrefused}} =
             Linear.file_upload("token_123", "file.png", "image/png", 4, "DATA")
  end

  test "create_issue/3 supports keyword list attrs and formats issue with nil state" do
    created_issue = %{
      "id" => "lin_kw_1",
      "identifier" => "ENG-99",
      "title" => "Keyword Issue",
      "description" => "Description",
      "state" => nil,
      "branchName" => nil,
      "url" => "https://linear.app/issue/ENG-99",
      "createdAt" => "2026-09-05T10:00:00.000Z",
      "updatedAt" => "2026-09-05T10:00:00.000Z"
    }

    LinearMock.mock_create_issue_success(created_issue)

    assert {:ok,
            %{
              id: "lin_kw_1",
              identifier: "ENG-99",
              state: nil
            }} =
             Linear.create_issue("token_123",
               team_id: "team_1",
               title: "Keyword Issue",
               description: "Description"
             )
  end
end
